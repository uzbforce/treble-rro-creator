package main

// EROFS, read-only: the filesystem Android moved to for system, product and
// vendor partitions.
//
// This is the reason the unpacker does not shell out. simg2img and lpunpack can
// be found for Windows, but nothing on Windows reads EROFS — not 7-Zip, not the
// Android platform tools, not even a signed driver. The on-disk format is
// small, so it is parsed here instead, and the same code runs on Windows,
// Debian, Arch and Termux.
//
// Only what a firmware dump needs is implemented: walking directories and
// reading whole files. Compressed files are reported by name instead of being
// decoded wrongly — see the EROFS_INODE_COMPRESSED cases below.

import (
	"encoding/binary"
	"errors"
	"fmt"
	"strings"
)

const (
	erofsSuperOffset = 1024
	erofsMagic       = 0xe0f5e1e2

	erofsFeatureIncompat48Bit   = 0x80
	erofsFeatureIncompatChunked = 0x04

	// inode datalayouts, i_format bits 1..3
	erofsFlatPlain         = 0
	erofsCompressedFull    = 1
	erofsFlatInline        = 2
	erofsCompressedCompact = 3
	erofsChunkBased        = 4
)

type erofsInode struct {
	nid        int64
	mode       uint32
	size       int64
	datalayout int
	extended   bool
	startblk   int64
	chunkfmt   uint16
	inlineOff  int64 // where tail-packed data starts
	isize      int64 // 32 or 64: the on-disk inode body
	xattrSize  int64
}

type erofsImage struct {
	src          image
	blockSize    int64
	metaBlk      int64
	rootNid      int64
	dirBlkSize   int64
	featIncompat uint32
	chunked      bool
	zeroPadding  bool
	xattrBlk     int64
}

func newEROFSImage(src image) (*erofsImage, error) {
	var sb [128]byte
	if _, err := src.ReadAt(sb[:], erofsSuperOffset); err != nil {
		return nil, err
	}
	if binary.LittleEndian.Uint32(sb[0:]) != erofsMagic {
		return nil, errors.New("not an EROFS image")
	}
	blkBits := int(sb[12])
	if blkBits < 9 || blkBits > 16 {
		return nil, fmt.Errorf("erofs: block size 2^%d is not credible", blkBits)
	}
	e := &erofsImage{
		src:          src,
		blockSize:    1 << blkBits,
		metaBlk:      int64(binary.LittleEndian.Uint32(sb[40:])),
		featIncompat: binary.LittleEndian.Uint32(sb[80:]),
		xattrBlk:     int64(binary.LittleEndian.Uint32(sb[44:])),
	}
	// The zero-padding feature lets a compressed pcluster start with filler
	// zeroes; without it the first byte is the start of the LZ4 stream.
	e.zeroPadding = e.featIncompat&0x1 != 0
	if e.featIncompat&erofsFeatureIncompat48Bit != 0 {
		// 48-bit images address metadata differently (a base offset per
		// inode); reading one with 32-bit arithmetic would silently be wrong.
		return nil, errors.New("erofs: 48-bit images are not supported")
	}
	e.rootNid = int64(binary.LittleEndian.Uint16(sb[14:]))
	e.chunked = e.featIncompat&erofsFeatureIncompatChunked != 0
	e.dirBlkSize = e.blockSize
	if bits := int(sb[90]); bits >= blkBits && bits <= 16 {
		e.dirBlkSize = 1 << bits
	}
	if e.rootNid <= 0 {
		return nil, errors.New("erofs: the superblock has no root inode")
	}
	return e, nil
}

func (e *erofsImage) Kind() string { return "erofs" }

// iloc is the byte offset of an inode on disk: nids count 32-byte slots from
// the start of the metadata area.
func (e *erofsImage) iloc(nid int64) int64 {
	return e.metaBlk*e.blockSize + nid*32
}

func (e *erofsImage) inode(nid int64) (*erofsInode, error) {
	off := e.iloc(nid)
	var raw [64]byte
	if _, err := e.src.ReadAt(raw[:], off); err != nil {
		return nil, fmt.Errorf("erofs: cannot read inode %d: %w", nid, err)
	}
	format := binary.LittleEndian.Uint16(raw[0:])
	in := &erofsInode{
		nid:        nid,
		datalayout: int((format >> 1) & 0x07),
		extended:   format&0x01 != 0,
	}
	var ib = raw[:]
	if in.extended {
		in.isize = 64
		in.mode = uint32(binary.LittleEndian.Uint16(ib[4:]))
		in.size = int64(binary.LittleEndian.Uint64(ib[8:]))
	} else {
		in.isize = 32
		in.mode = uint32(binary.LittleEndian.Uint16(ib[4:]))
		in.size = int64(binary.LittleEndian.Uint32(ib[8:]))
	}
	xattrCount := int64(binary.LittleEndian.Uint16(ib[2:]))
	if xattrCount > 0 {
		in.xattrSize = 12 + 4*(xattrCount-1)
	}
	in.inlineOff = off + in.isize + in.xattrSize
	// raw_blkaddr is unsigned on disk; 0xffffffff means "no data blocks",
	// which is the normal state of a fully tail-packed inline file.
	in.startblk = int64(int32(binary.LittleEndian.Uint32(ib[16:])))
	if in.datalayout == erofsChunkBased {
		in.chunkfmt = binary.LittleEndian.Uint16(ib[16:])
	}
	if in.size < 0 || in.size > 1<<40 {
		return nil, fmt.Errorf("erofs: inode %d claims a size of %d bytes", nid, in.size)
	}
	return in, nil
}

func (in *erofsInode) isDir() bool { return in.mode&0xf000 == 0x4000 }

// readInode returns the whole inode data. Directories and the handful of text
// files the probe reads are small; a big APK is the largest thing that ever
// goes through here and it is capped by the caller.
func (e *erofsImage) readInode(in *erofsInode) ([]byte, error) {
	if in.size == 0 {
		return nil, nil
	}
	out := make([]byte, in.size)
	switch in.datalayout {
	case erofsFlatPlain:
		if in.startblk < 0 {
			return nil, errors.New("erofs: inode has no data blocks")
		}
		if _, err := e.src.ReadAt(out, in.startblk*e.blockSize); err != nil {
			return nil, err
		}
		return out, nil

	case erofsFlatInline:
		// The file's full blocks live where raw_blkaddr points; the last,
		// short block is packed after the inode itself.
		tailStart := in.size / e.blockSize * e.blockSize
		if tailStart > 0 {
			if in.startblk < 0 {
				return nil, errors.New("erofs: inode has no data blocks")
			}
			if _, err := e.src.ReadAt(out[:tailStart], in.startblk*e.blockSize); err != nil {
				return nil, err
			}
		}
		if _, err := e.src.ReadAt(out[tailStart:], in.inlineOff); err != nil {
			return nil, err
		}
		return out, nil

	case erofsChunkBased:
		unit := int64(4)
		if in.chunkfmt&0x20 != 0 {
			unit = 8
		}
		chunkBits := int64(in.chunkfmt&0x1f) + int64(bitsOf(e.blockSize))
		chunkSize := int64(1) << chunkBits
		idxBase := alignUp(in.inlineOff, unit)
		for off := int64(0); off < in.size; off += chunkSize {
			chunkNr := off >> chunkBits
			var idx [8]byte
			if _, err := e.src.ReadAt(idx[:unit], idxBase+unit*chunkNr); err != nil {
				return nil, err
			}
			var start int64
			if unit == 8 {
				start = int64(binary.LittleEndian.Uint32(idx[4:])) |
					int64(binary.LittleEndian.Uint16(idx[0:]))<<32
			} else {
				start = int64(binary.LittleEndian.Uint32(idx[0:]))
			}
			n := chunkSize
			if off+n > in.size {
				n = in.size - off
			}
			if start == 0xffffffff || start == 0xffffffffffff {
				continue // a hole: already zero
			}
			if _, err := e.src.ReadAt(out[off:off+n], start*e.blockSize); err != nil {
				return nil, err
			}
		}
		return out, nil

	case erofsCompressedFull, erofsCompressedCompact:
		return e.readCompressed(in)
	}
	return nil, fmt.Errorf("erofs: unknown inode layout %d", in.datalayout)
}

func bitsOf(n int64) int {
	b := 0
	for 1<<b < n {
		b++
	}
	return b
}

func alignUp(n, to int64) int64 {
	if to <= 1 {
		return n
	}
	if r := n % to; r != 0 {
		n += to - r
	}
	return n
}

// dirent is one directory entry. In EROFS a block starts with a run of
// 12-byte entries and their names follow in the same block; nameoff is a byte
// offset from the start of the block, so a name ends where the next entry's
// name starts. That is why there is no name length field to read.
type erofsDirent struct {
	name string
	nid  int64
}

const erofsDirentSize = 12

func (e *erofsImage) dirEntries(in *erofsInode) ([]erofsDirent, error) {
	data, err := e.readInode(in)
	if err != nil {
		return nil, err
	}
	var out []erofsDirent
	for base := int64(0); base < int64(len(data)); base += e.dirBlkSize {
		end := base + e.dirBlkSize
		if end > int64(len(data)) {
			end = int64(len(data))
		}
		blk := data[base:end]
		if len(blk) < erofsDirentSize {
			break
		}
		// The first entry's nameoff also says how many entries the block
		// holds: names start after the last of them.
		count := int(le16(blk[8:])) / erofsDirentSize
		if count <= 0 || count*erofsDirentSize > len(blk) {
			break
		}
		for i := 0; i < count; i++ {
			off := i * erofsDirentSize
			nid := int64(binary.LittleEndian.Uint64(blk[off:]))
			nameOff := int(le16(blk[off+8:]))
			nameEnd := len(blk)
			if i+1 < count {
				nameEnd = int(le16(blk[off+erofsDirentSize+8:]))
			}
			if nameOff < erofsDirentSize || nameOff > nameEnd || nameEnd > len(blk) {
				continue
			}
			name := string(blk[nameOff:nameEnd])
			if name == "" || name == "." || name == ".." || strings.IndexByte(name, 0) >= 0 {
				continue
			}
			out = append(out, erofsDirent{name: name, nid: nid})
		}
	}
	return out, nil
}

func (e *erofsImage) Walk(fn func(rel string, size int64, isDir bool) error) error {
	seen := map[int64]bool{}
	return e.walk(e.rootNid, "", fn, seen, 0)
}

func (e *erofsImage) walk(nid int64, prefix string, fn func(string, int64, bool) error, seen map[int64]bool, depth int) error {
	if depth > 64 || seen[nid] {
		return nil
	}
	seen[nid] = true
	in, err := e.inode(nid)
	if err != nil {
		return err
	}
	entries, err := e.dirEntries(in)
	if err != nil {
		return fmt.Errorf("%s: %w", orRoot(prefix), err)
	}
	for _, de := range entries {
		rel := de.name
		if prefix != "" {
			rel = prefix + "/" + de.name
		}
		child, err := e.inode(de.nid)
		if err != nil {
			return err
		}
		if err := fn(rel, child.size, child.isDir()); err != nil {
			return err
		}
		if child.isDir() {
			if err := e.walk(de.nid, rel, fn, seen, depth+1); err != nil {
				return err
			}
		}
	}
	return nil
}

// ReadPath reads one file by path, the way the extraction rules ask for files.
func (e *erofsImage) ReadPath(rel string) ([]byte, error) {
	in, err := e.lookup(rel)
	if err != nil {
		return nil, err
	}
	if in.isDir() {
		return nil, fmt.Errorf("erofs: %s is a folder", rel)
	}
	return e.readInode(in)
}

// lookup resolves a slash-separated path to its inode.
func (e *erofsImage) lookup(rel string) (*erofsInode, error) {
	cur := e.rootNid
	for _, part := range strings.Split(strings.Trim(rel, "/"), "/") {
		if part == "" {
			continue
		}
		in, err := e.inode(cur)
		if err != nil {
			return nil, err
		}
		if !in.isDir() {
			return nil, fmt.Errorf("erofs: %s is not a folder", rel)
		}
		entries, err := e.dirEntries(in)
		if err != nil {
			return nil, err
		}
		found := false
		for _, de := range entries {
			if de.name == part {
				cur = de.nid
				found = true
				break
			}
		}
		if !found {
			return nil, fmt.Errorf("erofs: %s does not exist", rel)
		}
	}
	return e.inode(cur)
}

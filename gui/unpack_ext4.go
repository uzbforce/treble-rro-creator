package main

// ext4, read-only: what system, product, vendor and odm images are when a ROM
// was not built with EROFS.
//
// A firmware dump only needs to walk directories and read small files, so this
// is a reader, not a filesystem: it parses the superblock and the group
// descriptor table to find one inode, then follows that inode's extent tree.
// Nothing is cached on disk and nothing is written.

import (
	"encoding/binary"
	"errors"
	"fmt"
	"strings"
)

const (
	ext4Magic = 0xef53

	ext4CompatHasJournal = 0x4
	ext4IncompatFiletype = 0x2
	ext4Incompat64Bit    = 0x80
	ext4IncompatInline   = 0x8000

	ext4ExtentsFlag = 0x80000
	ext4InlineData  = 0x10000000

	ext4ModeDir     = 0x4000
	ext4ModeRegular = 0x8000
	ext4ModeSymlink = 0xa000
)

type ext4Extent struct {
	logical int64
	length  int64
	phys    int64
}

type ext4Inode struct {
	ino     uint32
	mode    uint32
	size    int64
	flags   uint32
	block   [60]byte
	extents []ext4Extent // built lazily
	built   bool
}

type ext4Image struct {
	src            image
	blockSize      int64
	firstDataBlock int64
	inodesPerGroup int64
	inodeSize      int64
	descSize       int64
	gdtOff         int64
	incompat       uint32
}

func newExt4Image(src image) (*ext4Image, error) {
	var sb [1024]byte
	if _, err := src.ReadAt(sb[:], 1024); err != nil {
		return nil, err
	}
	if binary.LittleEndian.Uint16(sb[0x38:]) != ext4Magic {
		return nil, errors.New("not an ext4 image")
	}
	logBlock := int64(binary.LittleEndian.Uint32(sb[0x18:]))
	if logBlock > 6 {
		return nil, fmt.Errorf("ext4: block size 2^%d is not credible", logBlock)
	}
	e := &ext4Image{
		src:            src,
		blockSize:      1024 << uint(logBlock),
		firstDataBlock: int64(binary.LittleEndian.Uint32(sb[0x14:])),
		inodesPerGroup: int64(binary.LittleEndian.Uint32(sb[0x28:])),
		inodeSize:      128,
		descSize:       32,
		// s_feature_incompat, not s_feature_ro_compat: the two are adjacent
		// and reading the wrong one loses the 64-bit flag a modern image has.
		incompat: binary.LittleEndian.Uint32(sb[0x60:]),
	}
	rev := binary.LittleEndian.Uint32(sb[0x4c:])
	if rev >= 1 {
		if n := int64(binary.LittleEndian.Uint16(sb[0x58:])); n >= 128 && n <= 1024 {
			e.inodeSize = n
		}
	}
	if e.incompat&ext4Incompat64Bit != 0 {
		if n := int64(binary.LittleEndian.Uint16(sb[0xfe:])); n >= 64 && n <= 512 {
			e.descSize = n
		}
	}
	if e.inodesPerGroup <= 0 || e.inodesPerGroup > 1<<20 {
		return nil, errors.New("ext4: the superblock has no usable inode count per group")
	}
	e.gdtOff = (e.firstDataBlock + 1) * e.blockSize
	return e, nil
}

func (e *ext4Image) Kind() string { return "ext4" }

func (e *ext4Image) inode(ino uint32) (*ext4Inode, error) {
	if ino == 0 {
		return nil, errors.New("ext4: inode 0")
	}
	group := int64(ino-1) / e.inodesPerGroup
	index := int64(ino-1) % e.inodesPerGroup

	var desc [512]byte
	d := desc[:e.descSize]
	if _, err := e.src.ReadAt(d, e.gdtOff+group*e.descSize); err != nil {
		return nil, fmt.Errorf("ext4: group %d has no descriptor: %w", group, err)
	}
	table := int64(binary.LittleEndian.Uint32(d[8:]))
	if e.descSize >= 64 {
		table |= int64(binary.LittleEndian.Uint32(d[0x28:])) << 32
	}
	off := table*e.blockSize + index*e.inodeSize
	raw := make([]byte, e.inodeSize)
	if _, err := e.src.ReadAt(raw, off); err != nil {
		return nil, fmt.Errorf("ext4: cannot read inode %d: %w", ino, err)
	}

	in := &ext4Inode{
		ino:   ino,
		mode:  uint32(binary.LittleEndian.Uint16(raw[0:])),
		flags: binary.LittleEndian.Uint32(raw[0x20:]),
	}
	in.size = int64(binary.LittleEndian.Uint32(raw[4:]))
	if in.mode&0xf000 == ext4ModeRegular {
		in.size |= int64(binary.LittleEndian.Uint32(raw[0x6c:])) << 32
	}
	copy(in.block[:], raw[0x28:0x28+60])
	if in.size < 0 || in.size > 1<<40 {
		return nil, fmt.Errorf("ext4: inode %d claims %d bytes", ino, in.size)
	}
	return in, nil
}

// readExtentNode walks one node of an extent tree. A depth-0 node holds
// extents; a deeper node holds pointers to more nodes, so a 4 TB partition is
// still one small tree.
func (e *ext4Image) readExtentNode(node []byte, out *[]ext4Extent, depth int) error {
	if len(node) < 12 {
		return errors.New("ext4: a truncated extent node")
	}
	if binary.LittleEndian.Uint16(node[0:]) != 0xf30a {
		return errors.New("ext4: the extent tree has a bad header")
	}
	entries := int(binary.LittleEndian.Uint16(node[2:]))
	nodeDepth := int(binary.LittleEndian.Uint16(node[6:]))
	if entries < 0 || 12+entries*12 > len(node) {
		return errors.New("ext4: the extent tree has more entries than fit in its block")
	}
	if depth > 8 {
		return errors.New("ext4: the extent tree is deeper than it can be")
	}
	for i := 0; i < entries; i++ {
		rec := node[12+i*12:]
		if nodeDepth == 0 {
			length := int64(binary.LittleEndian.Uint16(rec[4:]))
			uninit := length > 32768
			if uninit {
				length -= 32768 // written in a later commit; reads as zeroes
			}
			// start_hi is at +6 and start_lo at +8, so the two halves of the
			// block number are not adjacent.
			phys := int64(binary.LittleEndian.Uint16(rec[6:]))<<32 | int64(binary.LittleEndian.Uint32(rec[8:]))
			if uninit {
				continue
			}
			*out = append(*out, ext4Extent{
				logical: int64(binary.LittleEndian.Uint32(rec[0:])),
				length:  length,
				phys:    phys,
			})
			continue
		}
		child := int64(binary.LittleEndian.Uint32(rec[4:])) |
			int64(binary.LittleEndian.Uint16(rec[8:]))<<32
		if child == 0 {
			continue
		}
		buf := make([]byte, e.blockSize)
		if _, err := e.src.ReadAt(buf, child*e.blockSize); err != nil {
			return err
		}
		if err := e.readExtentNode(buf, out, depth+1); err != nil {
			return err
		}
	}
	return nil
}

func (e *ext4Image) buildExtents(in *ext4Inode) error {
	if in.built {
		return nil
	}
	in.built = true
	if in.flags&ext4ExtentsFlag == 0 {
		return e.buildIndirect(in)
	}
	return e.readExtentNode(in.block[:], &in.extents, 0)
}

// buildIndirect turns the 12 direct entries and the single/double/triple
// indirect trees of an old-style inode into the same extent list, so reading a
// file has one path.
func (e *ext4Image) buildIndirect(in *ext4Inode) error {
	per := e.blockSize / 4
	var blocks []int64
	for i := 0; i < 12; i++ {
		blocks = append(blocks, int64(binary.LittleEndian.Uint32(in.block[i*4:])))
	}
	var walk func(blk int64, level int)
	walk = func(blk int64, level int) {
		if blk == 0 || level > 3 {
			return
		}
		buf := make([]byte, e.blockSize)
		if _, err := e.src.ReadAt(buf, blk*e.blockSize); err != nil {
			return
		}
		for i := int64(0); i < per; i++ {
			v := int64(binary.LittleEndian.Uint32(buf[i*4:]))
			if v == 0 {
				continue
			}
			if level == 0 {
				blocks = append(blocks, v)
			} else {
				walk(v, level-1)
			}
		}
	}
	walk(int64(binary.LittleEndian.Uint32(in.block[12*4:])), 0)
	walk(int64(binary.LittleEndian.Uint32(in.block[13*4:])), 1)
	walk(int64(binary.LittleEndian.Uint32(in.block[14*4:])), 2)

	for i, b := range blocks {
		if b == 0 {
			continue
		}
		in.extents = append(in.extents, ext4Extent{logical: int64(i), length: 1, phys: b})
	}
	return nil
}

func (e *ext4Image) readInode(in *ext4Inode, off, n int64) ([]byte, error) {
	if in.flags&ext4InlineData != 0 {
		return nil, errors.New("ext4: the file stores its data inline in the inode, which this reader skips")
	}
	if err := e.buildExtents(in); err != nil {
		return nil, err
	}
	out := make([]byte, n)
	done := int64(0)
	for done < n {
		pos := off + done
		blockNr := pos / e.blockSize
		inBlock := pos % e.blockSize
		chunk := e.blockSize - inBlock
		if chunk > n-done {
			chunk = n - done
		}
		var phys int64 = -1
		for _, ex := range in.extents {
			if blockNr >= ex.logical && blockNr < ex.logical+ex.length {
				phys = ex.phys + (blockNr - ex.logical)
				break
			}
		}
		if phys < 0 {
			// A hole reads as zeroes, which is also what an uninitialised
			// extent would give.
			done += chunk
			continue
		}
		if _, err := e.src.ReadAt(out[done:done+chunk], phys*e.blockSize+inBlock); err != nil {
			return nil, err
		}
		done += chunk
	}
	return out, nil
}

// ReadPath reads a whole file. Symlinks are not followed: the extraction rules
// only ever ask for regular files, and a link loop must not hang a dump.
func (e *ext4Image) ReadPath(rel string) ([]byte, error) {
	in, err := e.lookup(rel)
	if err != nil {
		return nil, err
	}
	if in.mode&0xf000 == ext4ModeDir {
		return nil, fmt.Errorf("ext4: %s is a folder", rel)
	}
	if in.mode&0xf000 == ext4ModeSymlink {
		// A short symlink keeps its target in i_block and a long one in a
		// data block; either way the file behind it is not this path.
		return nil, errors.New("ext4: that path is a symlink")
	}
	return e.readInode(in, 0, in.size)
}

func (e *ext4Image) lookup(rel string) (*ext4Inode, error) {
	cur := uint32(2) // the root inode is always 2
	for _, part := range strings.Split(strings.Trim(rel, "/"), "/") {
		if part == "" {
			continue
		}
		in, err := e.inode(cur)
		if err != nil {
			return nil, err
		}
		if in.mode&0xf000 != ext4ModeDir {
			return nil, fmt.Errorf("ext4: %s is not a folder", rel)
		}
		entries, err := e.dirEntries(in)
		if err != nil {
			return nil, err
		}
		found := false
		for _, de := range entries {
			if de.name == part {
				cur = de.ino
				found = true
				break
			}
		}
		if !found {
			return nil, fmt.Errorf("ext4: %s does not exist", rel)
		}
	}
	return e.inode(cur)
}

type ext4Dirent struct {
	name string
	ino  uint32
	dir  bool
}

func (e *ext4Image) dirEntries(in *ext4Inode) ([]ext4Dirent, error) {
	if in.size > 64<<20 {
		return nil, errors.New("ext4: the folder is larger than a folder can be")
	}
	data, err := e.readInode(in, 0, in.size)
	if err != nil {
		return nil, err
	}
	typed := e.incompat&ext4IncompatFiletype != 0
	var out []ext4Dirent
	for off := int64(0); off+8 <= int64(len(data)); {
		ino := binary.LittleEndian.Uint32(data[off:])
		recLen := int64(binary.LittleEndian.Uint16(data[off+4:]))
		nameLen := int64(data[off+6])
		fileType := data[off+7]
		if recLen < 8 || off+recLen > int64(len(data)) || nameLen > recLen-8 {
			break
		}
		name := string(data[off+8 : off+8+nameLen])
		if ino != 0 && name != "." && name != ".." && name != "" && strings.IndexByte(name, '/') < 0 {
			out = append(out, ext4Dirent{name: name, ino: ino, dir: typed && fileType == 2})
		}
		off += recLen
	}
	return out, nil
}

func (e *ext4Image) Walk(fn func(rel string, size int64, isDir bool) error) error {
	seen := map[uint32]bool{}
	return e.walk(2, "", fn, seen, 0)
}

func (e *ext4Image) walk(ino uint32, prefix string, fn func(string, int64, bool) error, seen map[uint32]bool, depth int) error {
	if depth > 64 || seen[ino] {
		return nil
	}
	seen[ino] = true
	in, err := e.inode(ino)
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
		child, err := e.inode(de.ino)
		if err != nil {
			return err
		}
		isDir := child.mode&0xf000 == ext4ModeDir
		if err := fn(rel, child.size, isDir); err != nil {
			return err
		}
		if isDir {
			if err := e.walk(de.ino, rel, fn, seen, depth+1); err != nil {
				return err
			}
		}
	}
	return nil
}

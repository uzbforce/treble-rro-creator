package main

// Image layers for the firmware unpacker.
//
// A firmware file is a stack of containers: a Samsung AP is a tar (often with
// an .md5 tail), inside it a super.img.lz4 is an LZ4 stream, that decompresses
// to an Android sparse image, which holds the LP metadata that says where each
// logical partition starts. Every layer except the outermost is random access
// only in appearance: the filesystem readers jump around, so each layer is
// turned into an io.ReaderAt and nothing above knows what is underneath.
//
// Nothing here shells out. lpunpack, simg2img, lz4 and 7z are the usual answer
// to this job, and between them they cover Linux and Termux but not Windows —
// and none of them can read EROFS at all (see unpack_erofs.go). Doing the
// parsing in Go means one code path on Windows, Debian, Arch and Termux, with
// no package manager, no root and no "install these five tools first".

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
)

// image is a random-access view of a disk image. Everything above this
// interface — the sparse decoder, the LZ4 decoder, the LP partition map, ext4
// and EROFS — only ever calls ReadAt.
type image interface {
	io.ReaderAt
	Size() int64
	Close() error
}

// ---------------------------------------------------------------------------
// Plain file
// ---------------------------------------------------------------------------

type rawImage struct {
	f *os.File
	n int64
}

func (r *rawImage) ReadAt(p []byte, off int64) (int, error) { return r.f.ReadAt(p, off) }
func (r *rawImage) Size() int64                             { return r.n }
func (r *rawImage) Close() error                            { return r.f.Close() }

// sectionImage is a window into another image: a tar entry, or one of the
// pieces of a super image. It shares the parent's file handle and must not
// close it, which is why Close is a no-op here.
type sectionImage struct {
	src image
	off int64
	n   int64
}

func section(src image, off, n int64) *sectionImage {
	if off > src.Size() {
		off = src.Size()
	}
	if off+n > src.Size() {
		n = src.Size() - off
	}
	if n < 0 {
		n = 0
	}
	return &sectionImage{src: src, off: off, n: n}
}

func (s *sectionImage) ReadAt(p []byte, off int64) (int, error) {
	if off >= s.n {
		return 0, io.EOF
	}
	if off+int64(len(p)) > s.n {
		p = p[:s.n-off]
	}
	n, err := s.src.ReadAt(p, s.off+off)
	return n, err
}

func (s *sectionImage) Size() int64  { return s.n }
func (s *sectionImage) Close() error { return nil }

// ---------------------------------------------------------------------------
// Android sparse image
// ---------------------------------------------------------------------------

const (
	sparseMagic      = 0xed26ff3a
	sparseChunkRaw   = 0xcac1
	sparseChunkFill  = 0xcac2
	sparseChunkDont  = 0xcac3
	sparseChunkCRC   = 0xcac4
	sparseHeaderSize = 28
	sparseChunkSize  = 12
)

// sparseChunk is one entry of the chunk table. The table is built up front so
// reads are a binary search instead of a walk: unpacking a 9 GB super image
// asks for thousands of blocks in arbitrary order.
type sparseChunk struct {
	out    int64 // offset in the expanded image
	n      int64 // length in the expanded image
	src    int64 // file offset of the payload (raw) or of the 4-byte filler
	fill   uint32
	unkind uint16
}

type sparseImage struct {
	src    image
	size   int64
	blk    int64
	chunks []sparseChunk
}

func newSparseImage(src image) (*sparseImage, error) {
	var h [sparseHeaderSize]byte
	if _, err := src.ReadAt(h[:], 0); err != nil {
		return nil, err
	}
	if binary.LittleEndian.Uint32(h[0:]) != sparseMagic {
		return nil, errors.New("not an Android sparse image")
	}
	fileHdr := int64(binary.LittleEndian.Uint16(h[8:]))
	chunkHdr := int64(binary.LittleEndian.Uint16(h[10:]))
	blk := int64(binary.LittleEndian.Uint32(h[12:]))
	totalBlks := int64(binary.LittleEndian.Uint32(h[16:]))
	chunks := int64(binary.LittleEndian.Uint32(h[20:]))
	if fileHdr <= 0 || chunkHdr < 12 || blk <= 0 || chunks <= 0 || chunks > 1<<24 {
		return nil, errors.New("the sparse image has a header that cannot be right")
	}

	img := &sparseImage{src: src, blk: blk, size: totalBlks * blk}
	if img.size <= 0 || img.size > 1<<40 {
		return nil, errors.New("the sparse image claims an impossible size")
	}
	img.chunks = make([]sparseChunk, 0, chunks)

	off := fileHdr
	var out int64
	for i := int64(0); i < chunks; i++ {
		var ch [12]byte
		if _, err := src.ReadAt(ch[:], off); err != nil {
			return nil, fmt.Errorf("the sparse chunk table ends early (%d of %d chunks): %w", i, chunks, err)
		}
		typ := binary.LittleEndian.Uint16(ch[0:])
		n := int64(binary.LittleEndian.Uint32(ch[4:])) * blk
		total := int64(binary.LittleEndian.Uint32(ch[8:]))
		if total < chunkHdr || n < 0 || out+n > img.size+img.blk {
			return nil, fmt.Errorf("sparse chunk %d is corrupt (type %#x, %d bytes)", i, typ, n)
		}
		c := sparseChunk{out: out, n: n, unkind: typ}
		switch typ {
		case sparseChunkRaw:
			c.src = off + chunkHdr
		case sparseChunkFill:
			var fill [4]byte
			if _, err := src.ReadAt(fill[:], off+chunkHdr); err != nil {
				return nil, err
			}
			c.fill = binary.LittleEndian.Uint32(fill[:])
		case sparseChunkDont, sparseChunkCRC:
		default:
			return nil, fmt.Errorf("sparse chunk %d has an unknown type %#x", i, typ)
		}
		img.chunks = append(img.chunks, c)
		out += n
		off += total
	}
	return img, nil
}

func (s *sparseImage) Size() int64  { return s.size }
func (s *sparseImage) Close() error { return nil }

func (s *sparseImage) ReadAt(p []byte, off int64) (int, error) {
	if off >= s.size {
		return 0, io.EOF
	}
	if off+int64(len(p)) > s.size {
		p = p[:s.size-off]
	}
	done := 0
	for done < len(p) {
		pos := off + int64(done)
		// The first chunk that ends after pos covers it.
		lo, hi := 0, len(s.chunks)
		for lo < hi {
			mid := (lo + hi) / 2
			if s.chunks[mid].out+s.chunks[mid].n <= pos {
				lo = mid + 1
			} else {
				hi = mid
			}
		}
		if lo >= len(s.chunks) {
			return done, io.EOF
		}
		c := s.chunks[lo]
		n := c.out + c.n - pos
		if n > int64(len(p)-done) {
			n = int64(len(p) - done)
		}
		switch c.unkind {
		case sparseChunkRaw:
			if _, err := s.src.ReadAt(p[done:done+int(n)], c.src+pos-c.out); err != nil {
				return done, err
			}
		case sparseChunkFill:
			for i := int64(0); i < n; i++ {
				shift := uint((pos - c.out + i) % 4 * 8)
				p[done+int(i)] = byte(c.fill >> shift)
			}
		default: // hole
			for i := int64(0); i < n; i++ {
				p[done+int(i)] = 0
			}
		}
		done += int(n)
	}
	return done, nil
}

// ---------------------------------------------------------------------------
// LZ4
// ---------------------------------------------------------------------------

const (
	lz4FrameMagic  = 0x184d2204
	lz4LegacyMagic = 0x184c2102
	lz4LegacyBlock = 8 << 20
)

// lz4Block is one independently decodable block of the stream. Building an
// index costs one pass over the container but no decompression, so a 9 GB
// super.img.lz4 is read without writing a 9 GB temp file, which is the one
// thing the usual `lz4 -d` route cannot avoid.
type lz4Block struct {
	src   int64 // offset of the compressed payload
	csize int64
	raw   bool  // stored, not compressed (frame format only)
	out   int64 // offset in the decoded stream
	osize int64
}

type lz4Image struct {
	src    image
	size   int64
	blocks []lz4Block
	cache  map[int][]byte // decoded blocks, small LRU by count
	order  []int
}

func newLZ4Image(src image) (*lz4Image, error) {
	var m [4]byte
	if _, err := src.ReadAt(m[:], 0); err != nil {
		return nil, err
	}
	img := &lz4Image{src: src, cache: map[int][]byte{}}
	switch binary.LittleEndian.Uint32(m[:]) {
	case lz4FrameMagic:
		if err := img.indexFrame(); err != nil {
			return nil, err
		}
	case lz4LegacyMagic:
		if err := img.indexLegacy(); err != nil {
			return nil, err
		}
	default:
		return nil, errors.New("not an LZ4 file")
	}
	if img.size <= 0 {
		return nil, errors.New("the LZ4 stream is empty")
	}
	return img, nil
}

func (l *lz4Image) indexFrame() error {
	var hdr [15]byte
	if _, err := l.src.ReadAt(hdr[:], 4); err != nil {
		return err
	}
	flg := hdr[0]
	if flg>>6 != 1 {
		return errors.New("unsupported LZ4 frame version")
	}
	blockIndep := flg&0x20 != 0
	if !blockIndep {
		// Linked blocks are allowed by the spec but never produced by the
		// tools Android firmwares are packed with; decoding them needs the
		// previous 64 KB of output, which a random-access reader does not have.
		return errors.New("this LZ4 stream uses linked blocks, which the unpacker cannot read")
	}
	maxBlock := int64(64<<10) << ((hdr[1] >> 4) & 7)
	if maxBlock > 4<<20 {
		maxBlock = 4 << 20
	}
	// A block checksum, when the writer asked for one, sits after each block's
	// payload. A content checksum only trails the end mark, and the index stops
	// at the end mark anyway.
	blockChecksum := int64(0)
	if flg&0x10 != 0 {
		blockChecksum = 4
	}
	contentSize := int64(-1)
	pos := int64(4 + 1 + 1)
	if flg&0x08 != 0 { // content size present
		var cs [8]byte
		if _, err := l.src.ReadAt(cs[:], pos); err != nil {
			return err
		}
		contentSize = int64(binary.LittleEndian.Uint64(cs[:]))
		pos += 8
	}
	if flg&0x01 != 0 { // dictionary id present
		pos += 4
	}
	pos++ // header checksum

	var out int64
	for {
		var bh [4]byte
		if _, err := l.src.ReadAt(bh[:], pos); err != nil {
			if err == io.EOF {
				break
			}
			return err
		}
		pos += 4
		raw := binary.LittleEndian.Uint32(bh[:])
		if raw == 0 {
			break // end mark
		}
		uncompressed := raw&0x80000000 != 0
		csize := int64(raw & 0x7fffffff)
		if csize <= 0 || csize > maxBlock || pos+csize > l.src.Size() {
			return errors.New("the LZ4 stream is truncated or corrupt")
		}
		b := lz4Block{src: pos, csize: csize, raw: uncompressed, out: out}
		if uncompressed {
			b.osize = csize
		} else {
			// Every block but the last holds a full block: the frame writer
			// flushes on a full buffer and only the tail is short.
			b.osize = maxBlock
		}
		l.blocks = append(l.blocks, b)
		out += b.osize
		pos += csize + blockChecksum
	}
	if n := len(l.blocks); n > 0 && !l.blocks[n-1].raw {
		last := &l.blocks[n-1]
		switch {
		case contentSize >= 0 && contentSize >= last.out:
			last.osize = contentSize - last.out
		default:
			data, err := l.decode(*last)
			if err != nil {
				return err
			}
			last.osize = int64(len(data))
		}
		if last.osize > maxBlock {
			return errors.New("the last LZ4 block is larger than the frame allows")
		}
	}
	l.size = 0
	for _, b := range l.blocks {
		l.size += b.osize
	}
	return nil
}

func (l *lz4Image) indexLegacy() error {
	pos := int64(4)
	var out int64
	for pos+4 <= l.src.Size() {
		var bh [4]byte
		if _, err := l.src.ReadAt(bh[:], pos); err != nil {
			break
		}
		pos += 4
		csize := int64(binary.LittleEndian.Uint32(bh[:]))
		if csize <= 0 || csize > lz4LegacyBlock || pos+csize > l.src.Size() {
			break
		}
		b := lz4Block{src: pos, csize: csize, out: out, raw: csize == lz4LegacyBlock}
		// The legacy format has no block header, so the decoded length of the
		// last block is only known by decoding it. Every other block is full.
		if pos+csize == l.src.Size() {
			if b.raw {
				b.osize = csize
			} else {
				n, err := l.decode(b)
				if err != nil {
					return err
				}
				b.osize = int64(len(n))
			}
		} else {
			b.osize = lz4LegacyBlock
		}
		l.blocks = append(l.blocks, b)
		out += b.osize
		pos += csize
	}
	l.size = out
	return nil
}

func (l *lz4Image) Size() int64  { return l.size }
func (l *lz4Image) Close() error { return nil }

func (l *lz4Image) decode(b lz4Block) ([]byte, error) {
	buf := make([]byte, b.csize)
	if _, err := l.src.ReadAt(buf, b.src); err != nil {
		return nil, err
	}
	if b.raw {
		return buf, nil
	}
	size := b.osize
	if size <= 0 {
		size = lz4LegacyBlock
	}
	out := make([]byte, size)
	n, err := lz4Decode(buf, out)
	if err != nil {
		return nil, err
	}
	return out[:n], nil
}

func (l *lz4Image) block(pos int64) ([]byte, int64, error) {
	lo, hi := 0, len(l.blocks)
	for lo < hi {
		mid := (lo + hi) / 2
		if l.blocks[mid].out+l.blocks[mid].osize <= pos {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo >= len(l.blocks) {
		return nil, 0, io.EOF
	}
	if data, ok := l.cache[lo]; ok {
		return data, l.blocks[lo].out, nil
	}
	data, err := l.decode(l.blocks[lo])
	if err != nil {
		return nil, 0, err
	}
	if len(l.cache) >= 4 {
		delete(l.cache, l.order[0])
		l.order = l.order[1:]
	}
	l.cache[lo] = data
	l.order = append(l.order, lo)
	return data, l.blocks[lo].out, nil
}

func (l *lz4Image) ReadAt(p []byte, off int64) (int, error) {
	if off >= l.size {
		return 0, io.EOF
	}
	if off+int64(len(p)) > l.size {
		p = p[:l.size-off]
	}
	done := 0
	for done < len(p) {
		data, base, err := l.block(off + int64(done))
		if err != nil {
			return done, err
		}
		start := off + int64(done) - base
		if start >= int64(len(data)) {
			return done, io.ErrUnexpectedEOF
		}
		n := copy(p[done:], data[start:])
		done += n
	}
	return done, nil
}

// lz4Decode decompresses one LZ4 block. The format is a sequence of runs: a
// token whose high nibble is a literal length and low nibble a match length,
// then the literals, a 16-bit distance and the match copy. Extended lengths
// continue in 255-byte steps; matches may overlap the bytes they produce,
// which is why the copy is byte by byte.
func lz4Decode(src, dst []byte) (int, error) {
	var si, di int
	for si < len(src) {
		token := src[si]
		si++
		lit := int(token >> 4)
		if lit == 15 {
			for si < len(src) {
				b := src[si]
				si++
				lit += int(b)
				if b != 255 {
					break
				}
			}
		}
		if si+lit > len(src) || di+lit > len(dst) {
			return 0, errors.New("the LZ4 block is corrupt")
		}
		copy(dst[di:], src[si:si+lit])
		si += lit
		di += lit
		if si == len(src) {
			break // the block ends on a literal run
		}
		if si+2 > len(src) {
			return 0, errors.New("the LZ4 block is truncated")
		}
		dist := int(src[si]) | int(src[si+1])<<8
		si += 2
		if dist == 0 || dist > di {
			return 0, errors.New("the LZ4 block has a match before the start of the output")
		}
		match := int(token & 0x0f)
		if match == 15 {
			for si < len(src) {
				b := src[si]
				si++
				match += int(b)
				if b != 255 {
					break
				}
			}
		}
		match += 4
		if di+match > len(dst) {
			return 0, errors.New("the LZ4 block decompresses past the block size")
		}
		for i := 0; i < match; i++ {
			dst[di] = dst[di-dist]
			di++
		}
	}
	return di, nil
}

// lz4DecodePartial is lz4Decode for a pcluster whose decompressed length is not
// known up front: it stops as soon as dst is full, cutting the last match, the
// way LZ4_decompress_safe_partial does. EROFS needs that because a file can end
// in the middle of a pcluster.
func lz4DecodePartial(src, dst []byte) (int, error) {
	var si, di int
	for si < len(src) {
		token := src[si]
		si++
		lit := int(token >> 4)
		if lit == 15 {
			for si < len(src) {
				b := src[si]
				si++
				lit += int(b)
				if b != 255 {
					break
				}
			}
		}
		if lit > 0 {
			if si+lit > len(src) {
				return 0, errors.New("the LZ4 block is truncated")
			}
			if di+lit >= len(dst) {
				return copy(dst[di:], src[si:si+lit]) + di, nil
			}
			copy(dst[di:], src[si:si+lit])
			si += lit
			di += lit
		}
		if si == len(src) {
			break
		}
		if si+2 > len(src) {
			return 0, errors.New("the LZ4 block is truncated")
		}
		dist := int(src[si]) | int(src[si+1])<<8
		si += 2
		if dist == 0 || dist > di {
			return 0, errors.New("the LZ4 block has a match before the start of the output")
		}
		match := int(token & 0x0f)
		if match == 15 {
			for si < len(src) {
				b := src[si]
				si++
				match += int(b)
				if b != 255 {
					break
				}
			}
		}
		match += 4
		for i := 0; i < match; i++ {
			dst[di] = dst[di-dist]
			di++
			if di == len(dst) {
				return di, nil
			}
		}
	}
	if di != len(dst) {
		return 0, errors.New("the LZ4 block decoded to fewer bytes than the file needs")
	}
	return di, nil
}

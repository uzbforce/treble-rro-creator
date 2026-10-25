package main

// super.img: the LP metadata and the logical partitions it describes.
//
// A super image is a container, not a filesystem. The first 12 KB are a
// reserved area and two copies of a geometry block; after them come the
// metadata slots (metadata_max_size each, one per A/B slot), and after those
// the partition data. Each partition is a list of extents: "N sectors of this
// container, starting at byte X". Read through that list and a partition looks
// like a plain image, which is what the ext4 and EROFS readers want.
//
// This is what `lpunpack` does. Doing it here removes a build-tools download
// from every platform.

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"strings"
)

const (
	lpGeometryMagic  = 0x616c4467
	lpMetadataMagic  = 0x414c5030
	lpReservedBytes  = 4096
	lpGeometrySize   = 4096
	lpMaxHeaderSize  = 64 << 10
	lpMaxMetadata    = 64 << 20
	lpMaxTableOffset = lpMaxMetadata
)

// lpExtent is one "linear" mapping: numSectors of the container at targetData.
// targetType is 0 for a plain mapping; zeroing and "replace" targets are not
// written by any shipping super image.
type lpExtent struct {
	numSectors uint64
	targetType uint32
	targetData uint64
}

// lpPartition is a logical partition in the order it appears in super.img.
type lpPartition struct {
	Name        string
	Attributes  uint32
	FirstExtent uint32
	NumExtents  uint32
	Group       uint32
	GroupName   string
}

// superImage answers two questions about a super.img: which partitions it
// holds, and what bytes one of them starts with.
type superImage struct {
	src        image
	partitions []lpPartition
	extents    []lpExtent
	slot       int
	headerSize int64
}

// newSuperImage parses the geometry and the first readable metadata slot.
//
// The metadata does not always start at the same byte: the layout depends on
// the liblp version that wrote the image (some have one geometry block, some
// two). Rather than hard-code one offset and fail on the other, the magic is
// searched for in the first megabyte and every candidate is validated before it
// is trusted.
func newSuperImage(src image) (*superImage, error) {
	var geo [lpGeometrySize]byte
	if _, err := src.ReadAt(geo[:], lpReservedBytes); err != nil {
		return nil, fmt.Errorf("super.img: cannot read the geometry block: %w", err)
	}
	if binary.LittleEndian.Uint32(geo[0:]) != lpGeometryMagic {
		return nil, errors.New("super.img: no LP geometry at 4096 — this is not a super image")
	}
	geomSize := binary.LittleEndian.Uint32(geo[4:])
	if geomSize < 52 || geomSize > lpGeometrySize {
		return nil, fmt.Errorf("super.img: geometry size %d is not a super image layout", geomSize)
	}
	maxSize := int64(binary.LittleEndian.Uint32(geo[40:]))
	slots := int(binary.LittleEndian.Uint32(geo[44:]))
	if maxSize <= 0 || maxSize > lpMaxMetadata || slots < 1 || slots > 8 {
		return nil, fmt.Errorf("super.img: geometry says %d bytes per metadata slot × %d slots, which is not credible", maxSize, slots)
	}

	scanLen := int64(lpReservedBytes + lpGeometrySize*2 + maxSize)
	if scanLen > src.Size() {
		scanLen = src.Size()
	}
	if scanLen > 4<<20 {
		scanLen = 4 << 20 // the metadata always starts near the front
	}
	buf := make([]byte, scanLen)
	if _, err := src.ReadAt(buf, 0); err != nil && err != io.EOF {
		return nil, err
	}

	var firstErr error
	for off := int64(lpReservedBytes); off+128 <= int64(len(buf)); off += 4 {
		if binary.LittleEndian.Uint32(buf[off:]) != lpMetadataMagic {
			continue
		}
		n := maxSize
		if off+n > src.Size() {
			n = src.Size() - off
		}
		block := make([]byte, n)
		if _, err := src.ReadAt(block, off); err != nil && err != io.EOF {
			return nil, err
		}
		sup, err := parseLPMetadata(block, maxSize)
		if err != nil {
			if firstErr == nil {
				firstErr = fmt.Errorf("super.img: metadata at %d: %w", off, err)
			}
			continue
		}
		sup.src = src
		sup.slot = int((off - (lpReservedBytes + lpGeometrySize*2)) / maxSize)
		if sup.slot < 0 {
			sup.slot = 0
		}
		return sup, nil
	}
	if firstErr != nil {
		return nil, firstErr
	}
	return nil, errors.New("super.img: the geometry is there but no metadata slot follows it")
}

// parseLPMetadata reads one full metadata block (header plus tables).
func parseLPMetadata(head []byte, maxSize int64) (*superImage, error) {
	version := binary.LittleEndian.Uint16(head[4:])
	headerSize := int64(binary.LittleEndian.Uint32(head[8:]))
	tablesSize := int64(binary.LittleEndian.Uint32(head[44:]))
	if headerSize < 80 || headerSize > lpMaxHeaderSize {
		return nil, fmt.Errorf("header size %d", headerSize)
	}
	if tablesSize <= 0 || tablesSize > maxSize || headerSize+tablesSize > maxSize {
		return nil, fmt.Errorf("tables size %d", tablesSize)
	}

	// The four descriptors sit at a fixed place in the header: partition
	// table, extent table, group table, block device table.
	type desc struct{ off, num, size uint32 }
	read := func(i int) desc {
		b := head[80+i*12:]
		return desc{binary.LittleEndian.Uint32(b[0:]), binary.LittleEndian.Uint32(b[4:]), binary.LittleEndian.Uint32(b[8:])}
	}
	parts, exts, _ := read(0), read(1), read(2)
	for _, d := range []desc{parts, exts} {
		if d.size == 0 || d.size > 128 {
			return nil, fmt.Errorf("table entry size %d", d.size)
		}
		if d.num > 4096 {
			return nil, fmt.Errorf("table holds %d entries", d.num)
		}
		if int64(d.off)+int64(d.num)*int64(d.size) > tablesSize || int64(d.off) > lpMaxTableOffset {
			return nil, fmt.Errorf("table at %d does not fit in %d bytes of tables", d.off, tablesSize)
		}
	}
	if version == 0 {
		return nil, errors.New("version 0")
	}

	if headerSize+tablesSize > int64(len(head)) {
		return nil, fmt.Errorf("the metadata block is shorter than its header claims")
	}
	// The tables start right after the header.
	raw := head[headerSize : headerSize+tablesSize]

	sup := &superImage{headerSize: headerSize}

	pbuf := raw[parts.off : int64(parts.off)+int64(parts.num)*int64(parts.size)]
	sup.partitions = make([]lpPartition, 0, parts.num)
	for i := int64(0); i < int64(parts.num); i++ {
		b := pbuf[i*int64(parts.size):]
		name := b[:36]
		if j := bytes.IndexByte(name, 0); j >= 0 {
			name = name[:j]
		}
		sup.partitions = append(sup.partitions, lpPartition{
			Name:        sanitizeName(string(name)),
			Attributes:  binary.LittleEndian.Uint32(b[36:]),
			FirstExtent: binary.LittleEndian.Uint32(b[40:]),
			NumExtents:  binary.LittleEndian.Uint32(b[44:]),
			Group:       binary.LittleEndian.Uint32(b[48:]),
		})
	}

	ebuf := raw[exts.off : int64(exts.off)+int64(exts.num)*int64(exts.size)]
	sup.extents = make([]lpExtent, 0, exts.num)
	for i := int64(0); i < int64(exts.num); i++ {
		b := ebuf[i*int64(exts.size):]
		sup.extents = append(sup.extents, lpExtent{
			numSectors: binary.LittleEndian.Uint64(b[0:]),
			targetType: binary.LittleEndian.Uint32(b[8:]),
			targetData: binary.LittleEndian.Uint64(b[12:]),
		})
	}

	for i := range sup.partitions {
		p := &sup.partitions[i]
		if int64(p.FirstExtent)+int64(p.NumExtents) > int64(len(sup.extents)) {
			return nil, fmt.Errorf("partition %q points at extents past the end of the table", p.Name)
		}
	}
	return sup, nil
}

// sanitizeName keeps a partition name usable as a folder name and in a log
// line: liblp allows only [A-Za-z0-9_-] but a corrupt table must not be able to
// write outside the output folder.
func sanitizeName(n string) string {
	if n == "" {
		return "unnamed"
	}
	var b strings.Builder
	for _, r := range n {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '_', r == '-', r == '.':
			b.WriteRune(r)
		default:
			b.WriteByte('_')
		}
	}
	out := b.String()
	if out == "." || out == ".." {
		return "unnamed"
	}
	return out
}

// Partitions returns the logical partitions of the active slot. A/B devices
// carry every partition twice (system_a, system_b) and only one copy is ever
// filled; the empty ones are dropped so the caller does not try to open a
// zero-length filesystem.
func (s *superImage) Partitions() []lpPartition {
	var out []lpPartition
	for _, p := range s.partitions {
		if len(s.partitionExtents(p)) == 0 {
			continue
		}
		if p.Attributes&0x2 != 0 { // LP_PARTITION_ATTR_DISABLED
			continue
		}
		out = append(out, p)
	}
	return out
}

func (s *superImage) partitionExtents(p lpPartition) []lpExtent {
	out := make([]lpExtent, 0, p.NumExtents)
	for i := p.FirstExtent; i < p.FirstExtent+p.NumExtents && int(i) < len(s.extents); i++ {
		out = append(out, s.extents[i])
	}
	return out
}

// Open returns one partition as an image. Reads are translated through the
// extent list, so a partition spread over three places in super.img reads as
// one contiguous filesystem.
func (s *superImage) Open(name string) (image, error) {
	for _, p := range s.partitions {
		if p.Name != name {
			continue
		}
		exts := s.partitionExtents(p)
		size := int64(0)
		for _, e := range exts {
			size += int64(e.numSectors) * 512
		}
		if size == 0 {
			return nil, fmt.Errorf("%s is empty in this super image", name)
		}
		for _, e := range exts {
			if e.targetType != 0 {
				return nil, fmt.Errorf("%s uses extent type %d, which is not a plain mapping", name, e.targetType)
			}
			if int64(e.targetData)*512+int64(e.numSectors)*512 > s.src.Size() {
				return nil, fmt.Errorf("%s runs past the end of the image", name)
			}
		}
		return &lpPartitionImage{src: s.src, exts: exts, n: size}, nil
	}
	return nil, fmt.Errorf("no partition named %q in this super image", name)
}

type lpPartitionImage struct {
	src  image
	exts []lpExtent
	n    int64
}

func (l *lpPartitionImage) Size() int64  { return l.n }
func (l *lpPartitionImage) Close() error { return nil }

func (l *lpPartitionImage) ReadAt(p []byte, off int64) (int, error) {
	if off >= l.n {
		return 0, io.EOF
	}
	if off+int64(len(p)) > l.n {
		p = p[:l.n-off]
	}
	done := 0
	var base int64
	for _, e := range l.exts {
		length := int64(e.numSectors) * 512
		end := base + length
		// base has to move past every extent, not only the skipped ones: a read
		// that spans two extents would otherwise stop after the first.
		if off+int64(done) >= end {
			base = end
			continue
		}
		if off+int64(done) < base {
			break
		}
		start := off + int64(done) - base
		n := length - start
		if n > int64(len(p)-done) {
			n = int64(len(p) - done)
		}
		// targetData is a sector number, not a byte offset: every extent in a
		// shipping super.img is sector-aligned.
		if _, err := l.src.ReadAt(p[done:done+int(n)], int64(e.targetData)*512+start); err != nil {
			return done, err
		}
		done += int(n)
		base = end
		if done == len(p) {
			return done, nil
		}
	}
	if done == 0 {
		return 0, io.EOF
	}
	// A short read has to say so: a ReaderAt that fills part of the buffer and
	// returns nil hides a truncated extent table behind zeroes.
	return done, io.ErrUnexpectedEOF
}

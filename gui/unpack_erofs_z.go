package main

// Compressed EROFS files, which is where build.prop, init.rc and every XML a
// probe reads usually live.
//
// A compressed file's data is stored as pclusters: "physical clusters", each a
// run of blocks that decompresses to a slice of the file. Next to the inode is a
// map from logical cluster to pcluster, and that map has two encodings —
// COMPRESSED_FULL (one 8-byte record per cluster) and COMPRESSED_COMPACT (records
// of 2 or 4 bytes packed into 32-byte groups, which is what Android's mkfs.erofs
// produces). Both are read here, following fs/erofs/zmap.c.
//
// The same upstream file says how the data is decoded: LZ4, plain (stored
// uncompressed, "shifted"), and — only when the image was made with the newer
// options — LZMA, deflate or zstd. Only LZ4 and plain are implemented, because
// they are the two a stock Android image uses; the others produce an error that
// names the file instead of wrong bytes.
//
// Sizes: an lcluster is the filesystem block (4096) unless the inode says
// otherwise, and a pcluster is one block unless the inode asked for "big
// pclusters", where the map records how many blocks it takes.

import (
	"encoding/binary"
	"errors"
	"fmt"
	"math/bits"
)

const (
	erofsAdviseCompacted2B  = 0x0001
	erofsAdviseBigPcluster1 = 0x0002
	erofsAdviseInlinePcl    = 0x0004
	erofsAdviseInterlaced   = 0x0008
	erofsAdviseFragment     = 0x0010
	erofsAdviseBigPcluster2 = 0x0020

	erofsLclusterPlain   = 0
	erofsLclusterHead1   = 1
	erofsLclusterNonHead = 2
	erofsLclusterHead2   = 3

	// The high bit of a non-head's delta[0] says "this pcluster is that many
	// blocks long" rather than "the head is that many clusters back".
	erofsLiD0Cblkcnt = 1 << 11

	erofsCompressionLZ4 = 0
)

// erofsZMap is one compressed inode's map header, decoded.
type erofsZMap struct {
	advise     uint16
	alg        [2]uint8
	lcluster   int64
	indexStart int64 // COMPRESSED_FULL: first 8-byte record
	packStart  int64 // COMPRESSED_COMPACT: first packed group
	totalIdx   int64
	c4bInitial int64
	c2b        int64
}

type erofsZRec struct {
	typ    uint8
	cofs   uint16
	pblk   int64
	delta0 uint16
	delta1 uint16
	cblks  int64
}

func (e *erofsImage) zmap(in *erofsInode) (*erofsZMap, error) {
	base := alignUp(e.iloc(in.nid)+in.isize+in.xattrSize, 8)
	var hdr [8]byte
	if _, err := e.src.ReadAt(hdr[:], base); err != nil {
		return nil, err
	}
	z := &erofsZMap{
		advise:     binary.LittleEndian.Uint16(hdr[4:]),
		alg:        [2]uint8{hdr[6] & 15, hdr[6] >> 4},
		lcluster:   e.blockSize << (hdr[7] & 15),
		indexStart: base + 8,
		packStart:  base + 8,
	}
	if z.advise&erofsAdviseFragment != 0 {
		return nil, errors.New("erofs: this file is stored in the image's packed inode, which this reader does not follow")
	}
	if z.advise&erofsAdviseInterlaced != 0 {
		return nil, errors.New("erofs: this file uses interlaced pclusters, which this reader does not decode")
	}
	if z.advise&erofsAdviseInlinePcl != 0 {
		// The last pcluster of a tail-packed file lives after the map, not at
		// pblk; decoding it as if it did would invent bytes, so say so.
		return nil, errors.New("erofs: this file's last pcluster is tail-packed, which this reader does not decode")
	}
	if z.lcluster < e.blockSize || z.lcluster > 1<<16 {
		return nil, fmt.Errorf("erofs: a cluster size of %d bytes is not credible", z.lcluster)
	}
	z.totalIdx = (in.size + z.lcluster - 1) / z.lcluster
	if in.datalayout == erofsCompressedCompact {
		// The packed groups start on a 32-byte boundary, and the first few
		// records are 4-byte so that the 2-byte run after them is aligned.
		z.c4bInitial = ((32 - z.packStart%32) / 4) & 7
		if z.advise&erofsAdviseCompacted2B != 0 && z.c4bInitial < z.totalIdx {
			z.c2b = (z.totalIdx - z.c4bInitial) / 16 * 16
		}
	}
	return z, nil
}

// zload reads the map record for one logical cluster.
func (e *erofsImage) zload(in *erofsInode, z *erofsZMap, lcn int64) (erofsZRec, error) {
	if in.datalayout == erofsCompressedCompact {
		return e.zloadCompact(z, lcn)
	}
	return e.zloadFull(z, lcn)
}

func (e *erofsImage) zloadFull(z *erofsZMap, lcn int64) (erofsZRec, error) {
	var b [8]byte
	if _, err := e.src.ReadAt(b[:], z.indexStart+lcn*8); err != nil {
		return erofsZRec{}, err
	}
	r := erofsZRec{typ: uint8(binary.LittleEndian.Uint16(b[0:]) & 3)}
	if r.typ == erofsLclusterNonHead {
		r.cofs = uint16(z.lcluster)
		r.delta0 = binary.LittleEndian.Uint16(b[4:])
		if r.delta0&erofsLiD0Cblkcnt != 0 {
			if z.advise&(erofsAdviseBigPcluster1|erofsAdviseBigPcluster2) == 0 {
				return r, errors.New("erofs: a pcluster length without the big-pcluster feature")
			}
			r.cblks = int64(r.delta0 &^ erofsLiD0Cblkcnt)
			r.delta0 = 1
		}
		r.delta1 = binary.LittleEndian.Uint16(b[6:])
	} else {
		r.cofs = binary.LittleEndian.Uint16(b[2:])
		r.pblk = int64(binary.LittleEndian.Uint32(b[4:]))
	}
	return r, nil
}

// decodeCompactedBits pulls one record out of a packed group: `lobits` bits of
// offset followed by two bits of type.
func decodeCompactedBits(lobits int, in []byte, pos int64) (uint32, uint8) {
	at := pos / 8
	if at < 0 || at+4 > int64(len(in)) {
		return 0, erofsLclusterNonHead
	}
	v := binary.LittleEndian.Uint32(in[at:]) >> (pos & 7)
	lo := v & (1<<lobits - 1)
	return lo, uint8(v >> lobits & 3)
}

func (e *erofsImage) zloadCompact(z *erofsZMap, lcn int64) (erofsZRec, error) {
	lclusterBits := int64(bits.Len64(uint64(z.lcluster)) - 1)
	if lcn >= z.totalIdx || lclusterBits > 14 {
		return erofsZRec{}, errors.New("erofs: a compacted map record outside the file")
	}

	pos, lc, shift := z.packStart, lcn, int64(2)
	if lc >= z.c4bInitial {
		pos += z.c4bInitial * 4
		lc -= z.c4bInitial
		if lc < z.c2b {
			shift = 1
		} else {
			pos += z.c2b * 2
			lc -= z.c2b
		}
	}
	pos += lc * (1 << shift)

	// A group holds two 4-byte records or sixteen 2-byte records, and both
	// groups are 32 bytes once the shared base address is counted.
	vcnt := int64(16)
	if shift == 2 {
		vcnt = 2
	}
	packSize := vcnt << shift
	if shift == 2 && lclusterBits > 14 || shift == 1 && lclusterBits > 12 {
		return erofsZRec{}, errors.New("erofs: a packed group this reader cannot decode")
	}
	pack := make([]byte, packSize)
	if _, err := e.src.ReadAt(pack, pos-pos%packSize); err != nil {
		return erofsZRec{}, err
	}

	lobits := int(lclusterBits)
	if lobits < 12 {
		lobits = 12
	}
	encodeBits := (packSize - 4) * 8 / vcnt
	i := int((pos % packSize) >> shift)

	lo, typ := decodeCompactedBits(lobits, pack, int64(encodeBits)*int64(i))
	r := erofsZRec{typ: typ}
	if typ == erofsLclusterNonHead {
		r.cofs = uint16(z.lcluster)
		if lo&erofsLiD0Cblkcnt != 0 {
			if z.advise&(erofsAdviseBigPcluster1|erofsAdviseBigPcluster2) == 0 {
				return r, errors.New("erofs: a pcluster length without the big-pcluster feature")
			}
			r.cblks = int64(lo &^ erofsLiD0Cblkcnt)
			r.delta0 = 1
			return r, nil
		}
		if i+1 != int(vcnt) {
			r.delta0 = uint16(lo)
			return r, nil
		}
		// The last record of a group stores delta[1] in a non-head's slot, so
		// its delta[0] is one more than the record before it.
		lo2, typ2 := decodeCompactedBits(lobits, pack, int64(encodeBits)*int64(i-1))
		if typ2 != erofsLclusterNonHead {
			lo2 = 0
		} else if lo2&erofsLiD0Cblkcnt != 0 {
			lo2 = 1
		}
		r.delta0 = uint16(lo2 + 1)
		return r, nil
	}

	r.cofs = uint16(lo)
	// A head's physical block is stored once per group, as a base address, and
	// every head before it in the group adds one: records only carry the count.
	nblk := int64(1)
	if z.advise&erofsAdviseBigPcluster1 == 0 {
		for i > 0 {
			i--
			lo2, typ2 := decodeCompactedBits(lobits, pack, int64(encodeBits)*int64(i))
			if typ2 == erofsLclusterNonHead {
				i -= int(lo2)
			}
			if i >= 0 {
				nblk++
			}
		}
	} else {
		nblk = 0
		for i > 0 {
			i--
			lo2, typ2 := decodeCompactedBits(lobits, pack, int64(encodeBits)*int64(i))
			if typ2 == erofsLclusterNonHead {
				if lo2&erofsLiD0Cblkcnt != 0 {
					i--
					nblk += int64(lo2 &^ erofsLiD0Cblkcnt)
					continue
				}
				i -= int(lo2) - 2
				continue
			}
			nblk++
		}
	}
	r.pblk = int64(binary.LittleEndian.Uint32(pack[packSize-4:])) + nblk
	return r, nil
}

// readCompressed rebuilds a whole compressed file by walking its pclusters.
func (e *erofsImage) readCompressed(in *erofsInode) ([]byte, error) {
	z, err := e.zmap(in)
	if err != nil {
		return nil, err
	}
	out := make([]byte, in.size)
	lcn := int64(0)
	for lcn < z.totalIdx {
		head, err := e.zload(in, z, lcn)
		if err != nil {
			return nil, err
		}
		if head.typ == erofsLclusterNonHead {
			return nil, errors.New("erofs: a pcluster map that starts in the middle of a pcluster")
		}
		la := lcn*z.lcluster + int64(head.cofs)
		if la >= in.size {
			// mkfs can leave a record for the cluster that starts exactly at
			// EOF; there is nothing behind it.
			break
		}

		// The extent runs until the next head record.
		next := lcn + 1
		for next < z.totalIdx {
			r, err := e.zload(in, z, next)
			if err != nil {
				return nil, err
			}
			if r.typ != erofsLclusterNonHead {
				break
			}
			next++
		}
		end := in.size
		if next < z.totalIdx {
			r, err := e.zload(in, z, next)
			if err != nil {
				return nil, err
			}
			if e := next*z.lcluster + int64(r.cofs); e < end {
				end = e
			}
		}
		if la >= end {
			return nil, errors.New("erofs: a pcluster map that does not advance")
		}
		if next <= lcn {
			return nil, errors.New("erofs: a pcluster map that loops")
		}
		llen := end - la

		pblks, err := e.zPclusterBlocks(in, z, head, lcn)
		if err != nil {
			return nil, err
		}
		// pblk counts filesystem blocks; only the logical side uses lclusters.
		data, err := e.zDecode(in, z, head, pblks*e.blockSize, llen)
		if err != nil {
			return nil, err
		}
		copy(out[la:], data)
		lcn = next
	}
	return out, nil
}

// zPclusterBlocks is how many physical blocks the pcluster occupies. A plain or
// head record is one block wide unless the image asked for big pclusters, in
// which case the following non-head record can say otherwise.
func (e *erofsImage) zPclusterBlocks(in *erofsInode, z *erofsZMap, head erofsZRec, lcn int64) (int64, error) {
	big := z.advise&erofsAdviseBigPcluster1 != 0
	if head.typ == erofsLclusterHead2 || head.typ == erofsLclusterPlain {
		big = z.advise&erofsAdviseBigPcluster2 != 0
	}
	if !big || (lcn+1)*z.lcluster >= in.size {
		return 1, nil
	}
	r, err := e.zload(in, z, lcn+1)
	if err != nil {
		return 0, err
	}
	if r.cblks > 0 {
		return r.cblks, nil
	}
	return 1, nil
}

// zDecode returns the first `llen` bytes of one pcluster.
func (e *erofsImage) zDecode(in *erofsInode, z *erofsZMap, head erofsZRec, plen, llen int64) ([]byte, error) {
	if plen < llen && head.typ == erofsLclusterPlain {
		return nil, errors.New("erofs: an uncompressed pcluster is shorter than the file needs")
	}
	if plen <= 0 || plen > 1<<24 {
		return nil, fmt.Errorf("erofs: a pcluster of %d bytes is not credible", plen)
	}
	src := make([]byte, plen)
	if _, err := e.src.ReadAt(src, head.pblk*e.blockSize); err != nil {
		return nil, err
	}

	switch head.typ {
	case erofsLclusterPlain:
		return src[:llen], nil
	case erofsLclusterHead1, erofsLclusterHead2:
		alg := z.alg[0]
		if head.typ == erofsLclusterHead2 {
			alg = z.alg[1]
		}
		if alg != erofsCompressionLZ4 {
			return nil, fmt.Errorf("erofs: compression algorithm %d is not implemented (only lz4)", alg)
		}
		if e.zeroPadding {
			// With zero padding the compressed stream may start with zeros
			// that were written to fill a block; the kernel skips them.
			start := 0
			for start < len(src) && src[start] == 0 {
				start++
			}
			if start == len(src) {
				return nil, errors.New("erofs: a compressed pcluster is all zeroes")
			}
			src = src[start:]
		}
		out := make([]byte, llen)
		if _, err := lz4DecodePartial(src, out); err != nil {
			return nil, err
		}
		return out, nil
	}
	return nil, fmt.Errorf("erofs: unknown pcluster type %d", head.typ)
}

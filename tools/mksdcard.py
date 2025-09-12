#!/usr/bin/env python3
"""
SD Card Image Creator for ao486

Creates an SD card image by combining three input files:
- BIOS image at offset 0
- VGA BIOS image at offset 64KB
- Config sector at offset 96KB (sector 192, 193 and 194)
- Hard disk image at offset 128KB
"""

import sys
import os
import argparse
import struct


SECTOR_SIZE = 512
BIOS_OFFSET = 0
VGA_BIOS_OFFSET = 64 * 1024   # 64KB -> sectors 128..191
CFG_SECTOR = 192              # sector 192 (right after VGA BIOS)
CFG_OFFSET = CFG_SECTOR * SECTOR_SIZE
HDD_OFFSET = 128 * 1024       # 128KB -> sector 256


def decode_chs(head, sec_cyl, cyl_lo):
    """Decode packed CHS. Returns (valid, cyl, hd, sec)."""
    if head == 0xFF and sec_cyl == 0xFF and cyl_lo == 0xFF:
        return False, 0, 0, 0
    sec = sec_cyl & 0x3F
    cyl = ((sec_cyl & 0xC0) << 2) | cyl_lo
    if sec == 0:
        return False, 0, 0, 0
    return True, cyl, head, sec


def chs_to_lba(cyl, head, sec, heads, spt):
    return ((cyl * heads) + head) * spt + (sec - 1)


def calc_geometry_from_mbr(mbr_data: bytes, total_bytes: int):
    """Replicates verilator/ide.cpp calc_geometry in Python.
    Returns (cylinders, heads, spt)."""
    # Partition table entries start at 0x1BE
    entries = [mbr_data[0x1BE + i * 16: 0x1BE + (i + 1) * 16] for i in range(4)]
    candidates = [
        (255, 63),
        (240, 63), (224, 56),
        (128, 63), (64, 63), (32, 63), (16, 63),
        (15, 63), (15, 32),
        (8, 32), (4, 32),
    ]

    plausible = []
    for heads, spt in candidates:
        ok = True
        for e in entries:
            (boot, begHead, begSecCyl, begCylLo, ptype, endHead, endSecCyl, endCylLo,
             lbaStart, lbaSectors) = struct.unpack('<BBBBBBBBII', e)
            if ptype == 0:
                continue
            valid_beg, cs, hs, ss = decode_chs(begHead, begSecCyl, begCylLo)
            if valid_beg:
                lba_calc = chs_to_lba(cs, hs, ss, heads, spt)
                if lba_calc != lbaStart:
                    ok = False
            valid_end, ce, he, se = decode_chs(endHead, endSecCyl, endCylLo)
            if valid_end:
                lba_end = lbaStart + lbaSectors - 1
                lba_calc = chs_to_lba(ce, he, se, heads, spt)
                if lba_calc != lba_end:
                    ok = False
            if not ok:
                break
        if ok:
            plausible.append((heads, spt))

    if not plausible:
        # Fallback: typical translation
        heads, spt = 255, 63
    else:
        # Prefer spt=63, then larger head count
        plausible.sort(key=lambda x: (x[1], x[0]), reverse=True)
        heads, spt = plausible[0]

    cylinders = total_bytes // SECTOR_SIZE // heads // spt
    return cylinders, heads, spt


def build_identify_words(cyl: int, heads: int, spt: int):
    total = cyl * heads * spt
    ident = [0] * 256
    ident[0] = 0x0040
    ident[1] = min(16383, cyl)
    ident[3] = heads
    ident[4] = (512 * spt) & 0xFFFF
    ident[5] = 512
    ident[6] = spt
    # words 7..9 zero
    # words 10..19 serial "AOHD000      "
    ident[10] = (ord('A') << 8) | ord('O')
    ident[11] = (ord('H') << 8) | ord('D')
    ident[12] = (ord('0') << 8) | ord('0')
    ident[13] = (ord('0') << 8) | ord('0')
    ident[14] = (ord('0') << 8) | ord(' ')
    ident[15] = (ord(' ') << 8) | ord(' ')
    ident[16] = (ord(' ') << 8) | ord(' ')
    ident[17] = (ord(' ') << 8) | ord(' ')
    ident[18] = (ord(' ') << 8) | ord(' ')
    ident[19] = (ord(' ') << 8) | ord(' ')
    ident[20] = 3
    ident[21] = 512
    ident[22] = 4
    # 23..26 zero (firmware rev)
    # 27..46 model number "AO Harddrive            "
    model = "AO Harddrive".ljust(40)  # 20 words
    for i in range(20):
        ident[27 + i] = (ord(model[2 * i]) << 8) | ord(model[2 * i + 1])
    ident[47] = 16
    ident[48] = 1
    ident[49] = 1 << 9
    ident[50] = 0
    ident[51] = 0x0200
    ident[52] = 0x0200
    ident[53] = 0x0007
    ident[54] = min(16383, cyl)
    ident[55] = heads
    ident[56] = spt
    ident[57] = total & 0xFFFF
    ident[58] = (total >> 16) & 0xFFFF
    ident[59] = 0
    ident[60] = total & 0xFFFF
    ident[61] = (total >> 16) & 0xFFFF
    ident[62] = 0
    ident[63] = 0
    ident[64] = 0
    ident[65] = 120
    ident[66] = 120
    ident[67] = 120
    ident[68] = 120
    # 69..79 zero
    ident[80] = 0x007E
    ident[81] = 0
    ident[82] = 1 << 14
    ident[83] = (1 << 14) | (1 << 13) | (1 << 12) | (1 << 10)
    ident[84] = 1 << 14
    ident[85] = 1 << 14
    ident[86] = (1 << 14) | (1 << 13) | (1 << 12) | (1 << 10)
    ident[87] = 1 << 14
    ident[88] = 0
    # 89..92 zero
    ident[93] = 1 | (1 << 14) | 0x2000
    # 94..99 zero
    ident[100] = total & 0xFFFF
    ident[101] = (total >> 16) & 0xFFFF
    # rest zero
    return ident


def build_config_stream(mem_kb: int, hdd_path: str) -> bytes:
    """Build multi-sector config stream with {addr32, data32} pairs, terminated by addr=0.
    Includes CMOS, geometry, and IDENTIFY block (512 bytes -> 128 pairs -> 2 sectors)."""
    # CMOS values from init_cmos()
    pairs = []
    # Extended memory size in KB at CMOS 0x30/0x31
    pairs.append((0xF400 + 0x30, mem_kb & 0xFF))
    pairs.append((0xF400 + 0x31, (mem_kb >> 8) & 0xFF))
    # EQUIP configuration: https://wiki.nox-rhea.org/back2root/ibm-pc-ms-dos/interrupts/int_11/start
    equip = 1        # diskette exists
    equip |= 1 << 2  # PS/2 mouse exists
    equip |= 2 << 4  # initial mode 80x25 color
    pairs.append((0xF400 + 0x14, equip))  # diskette exists
    pairs.append((0xF400 + 0x10, 0x20))  # 1.2MB 5.25
    # Date
    pairs.append((0xF400 + 0x0D, 0x80))  # battery backed up
    
    pairs.append((0xF400 + 0x09, 0x24))  # year in BCD
    pairs.append((0xF400 + 0x08, 0x01))  # month
    pairs.append((0xF400 + 0x07, 0x01))  # day
    pairs.append((0xF400 + 0x32, 0x20))  # century

    # HDD geometry from MBR
    with open(hdd_path, 'rb') as f:
        mbr = f.read(SECTOR_SIZE)
        f.seek(0, os.SEEK_END)
        total_bytes = f.tell()
    cyl, heads, spt = calc_geometry_from_mbr(mbr, total_bytes)
    # 0xF001..0xF005 per ide.cpp
    pairs.append((0xF001, cyl))
    pairs.append((0xF002, heads))
    pairs.append((0xF003, spt))
    pairs.append((0xF004, spt * heads))
    pairs.append((0xF005, spt * heads * cyl))

    # Append IDENTIFY contents as 128 writes to 0xF000
    ident = build_identify_words(cyl, heads, spt)
    for i in range(128):
        lo = ident[2 * i] & 0xFFFF
        hi = ident[2 * i + 1] & 0xFFFF
        data = (hi << 16) | lo
        pairs.append((0xF000, data))

    # Serialize as little-endian {addr32, data32} pairs
    data = bytearray()
    for addr, val in pairs:
        data += struct.pack('<I', addr & 0xFFFFFFFF)
        data += struct.pack('<I', val & 0xFFFFFFFF)
    # termination word
    data += struct.pack('<I', 0)
    # pad to sector boundary
    if len(data) % SECTOR_SIZE:
        data += b'\x00' * (SECTOR_SIZE - (len(data) % SECTOR_SIZE))
    return bytes(data)


def create_sdcard_image(bios_file, vga_bios_file, hdd_file, output_file, mem_mb=2):
    """
    Create SD card image by combining three input files at specific offsets.
    
    Args:
        bios_file: Path to BIOS image file
        vga_bios_file: Path to VGA BIOS image file  
        hdd_file: Path to hard disk image file
        output_file: Path to output SD card image file
    """
    # Define offsets
    mem_kb = int(mem_mb-1) * 1024
    
    # Verify input files exist
    for file_path, name in [(bios_file, "BIOS"), (vga_bios_file, "VGA BIOS"), (hdd_file, "HDD")]:
        if not os.path.exists(file_path):
            print(f"Error: {name} file '{file_path}' not found")
            return False
    
    try:
        # Get file sizes
        bios_size = os.path.getsize(bios_file)
        vga_bios_size = os.path.getsize(vga_bios_file)
        hdd_size = os.path.getsize(hdd_file)
        
        # Check if BIOS will fit before VGA BIOS offset
        if bios_size > VGA_BIOS_OFFSET:
            print(f"Error: BIOS file too large ({bios_size} bytes), exceeds VGA BIOS offset ({VGA_BIOS_OFFSET} bytes)")
            return False
            
        # Check if VGA BIOS will fit before HDD offset
        if VGA_BIOS_OFFSET + vga_bios_size > HDD_OFFSET:
            print(f"Error: VGA BIOS file too large ({vga_bios_size} bytes), would overlap with HDD offset")
            return False
        
        # Calculate total image size
        total_size = HDD_OFFSET + hdd_size
        
        print(f"Creating SD card image '{output_file}':")
        print(f"  BIOS: {bios_file} ({bios_size} bytes) at offset 0x{BIOS_OFFSET:08X}")
        print(f"  VGA BIOS: {vga_bios_file} ({vga_bios_size} bytes) at offset 0x{VGA_BIOS_OFFSET:08X}")
        print(f"  CFG sector: 0x{CFG_OFFSET:08X} (sector {CFG_SECTOR}) with mem={mem_kb}KB")
        print(f"  HDD: {hdd_file} ({hdd_size} bytes) at offset 0x{HDD_OFFSET:08X}")
        print(f"  Total size: {total_size} bytes")
        
        # Create output image
        with open(output_file, 'wb') as outf:
            # Write BIOS at offset 0
            with open(bios_file, 'rb') as inf:
                outf.write(inf.read())
            
            # Pad to VGA BIOS offset
            current_pos = outf.tell()
            if current_pos < VGA_BIOS_OFFSET:
                outf.write(b'\x00' * (VGA_BIOS_OFFSET - current_pos))
            
            # Write VGA BIOS at 64KB offset
            with open(vga_bios_file, 'rb') as inf:
                outf.write(inf.read())
            
            # Pad to CFG sector offset
            current_pos = outf.tell()
            if current_pos < CFG_OFFSET:
                outf.write(b'\x00' * (CFG_OFFSET - current_pos))

            # Write config stream starting at sector 192 (expect ~3 sectors)
            cfg = build_config_stream(mem_kb, hdd_file)
            outf.write(cfg)

            # Pad to HDD offset (128KB)
            current_pos = outf.tell()
            if current_pos < HDD_OFFSET:
                outf.write(b'\x00' * (HDD_OFFSET - current_pos))
            
            # Write HDD image at 128KB offset
            with open(hdd_file, 'rb') as inf:
                outf.write(inf.read())
        
        print(f"Successfully created SD card image: {output_file}")
        return True
        
    except Exception as e:
        print(f"Error creating SD card image: {e}")
        return False


def main():
    parser = argparse.ArgumentParser(
        description="Create SD card image by combining BIOS, VGA BIOS, and HDD images"
    )
    parser.add_argument("bios", help="BIOS image file (placed at offset 0)")
    parser.add_argument("vga_bios", help="VGA BIOS image file (placed at offset 64KB)")
    parser.add_argument("hdd", help="Hard disk image file (placed at offset 128KB)")
    parser.add_argument("-o", "--output", default="sdcard.img", 
                       help="Output SD card image file (default: sdcard.img)")
    parser.add_argument("--mem", type=int, default=2,
                       help="Extended memory size (MB) to write to CMOS (default: 2)")
    
    args = parser.parse_args()
    
    success = create_sdcard_image(args.bios, args.vga_bios, args.hdd, args.output, args.mem)
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()

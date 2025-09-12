#include <stdint.h>
#include <stdio.h>

#include "Vsystem.h"
#include "Vsystem_ao486.h"
#include "Vsystem_system.h"

extern Vsystem tb;
extern void step();
struct PartEntry {
    uint8_t  boot;
    uint8_t  begHead;
    uint8_t  begSecCyl;
    uint8_t  begCylLo;
    uint8_t  type;
    uint8_t  endHead;
    uint8_t  endSecCyl;
    uint8_t  endCylLo;
    uint32_t lbaStart;
    uint32_t lbaSectors;
}  __attribute__((packed));

struct Geometry { uint16_t heads, spt; };

constexpr uint8_t CHS_INVALID = 0xFF;      //  FF FF FF marks “don’t care”

// Decode packed CHS into C/H/S numbers
inline bool decode_chs(uint8_t head,
    uint8_t sec_cyl,
    uint8_t cyl_lo,
    uint16_t &cyl,
    uint8_t  &hd,
    uint8_t  &sec)
{
    if (head == CHS_INVALID && sec_cyl == CHS_INVALID && cyl_lo == CHS_INVALID)
    return false;                           // special “invalid” marker

    hd  = head;
    sec =  sec_cyl & 0x3F;                      // lower 6 bits
    cyl = ((sec_cyl & 0xC0) << 2) | cyl_lo;     // upper 2 bits + 8 bits

    return !(sec == 0);                         // sector numbers must start at 1
}

// Convert CHS back to LBA for a *candidate* geometry
inline uint32_t chs_to_lba(uint16_t cyl, uint8_t head, uint8_t sec,
    uint16_t heads, uint16_t spt)
{
return ((uint32_t)cyl * heads + head) * spt + (sec - 1);
}

// extract CHS geometry from partition table
// mbr: 512 byte 1st sector of disk
static void calc_geometry(uint8_t *mbr, uint32_t *cylinders, uint16_t *heads, uint16_t *spt, uint64_t size)
{
    const PartEntry* pt = reinterpret_cast<const PartEntry*>(mbr + 0x1BE);
    // --- candidate table ---------------------------------------------------
    std::vector<Geometry> candidates = {
        {255,63},
        {240,63}, {224,56},           // “large” translation styles
        {128,63}, {64,63}, {32,63}, {16,63},
        {15,63}, {15,32},             // early IDE
        {8,32}, {4,32}                // XT‑IDE, very old BIOSes
    };

    std::vector<Geometry> plausible;

    for (const auto &g : candidates) {
        bool ok = true;

        for (size_t i = 0; i < 4 && ok; ++i) {
            const PartEntry &e = pt[i];
            if (e.type == 0)           // unused slot → ignore
                continue;

            // ----- start CHS -----
            uint16_t cs; uint8_t hs, ss;
            bool valid_beg = decode_chs(e.begHead, e.begSecCyl, e.begCylLo,
                                        cs, hs, ss);

            if (valid_beg) {
                uint32_t lbaCalc = chs_to_lba(cs, hs, ss, g.heads, g.spt);
                if (lbaCalc != e.lbaStart) ok = false;
            }

            // ----- end CHS -----
            uint16_t ce; uint8_t he, se;
            bool valid_end = decode_chs(e.endHead, e.endSecCyl, e.endCylLo,
                                        ce, he, se);

            if (valid_end) {
                uint32_t lbaEnd = e.lbaStart + e.lbaSectors - 1;
                uint32_t lbaCalc = chs_to_lba(ce, he, se, g.heads, g.spt);
                if (lbaCalc != lbaEnd) ok = false;
            }
        }
        if (ok) plausible.push_back(g);
    }

    // ---------------- print result ----------------
    if (plausible.empty()) {
        printf("No geometry fits every CHS/LBA pair; BIOS is likely using pure LBA "
                     "translation.\n");
        return;
    }

    // heuristic ranking: prefer SPT = 63, then larger head-count
    std::sort(plausible.begin(), plausible.end(),
              [](const Geometry &a, const Geometry &b) {
                  if (a.spt != b.spt)   return a.spt > b.spt;   // 63 first
                  return a.heads > b.heads;                     // 255 before 240, etc.
              });

    *heads = plausible[0].heads;
    *spt = plausible[0].spt;
    *cylinders = size / 512 / *heads / *spt;
    printf("IDE: calc_geometry: %u, %u, %u\n", *cylinders, *heads, *spt);
}

extern void ensure_posedge();
extern void full_step();

// This extracts geometry information from the partition table in the MBR, 
// constructs the corresponding 512-byte "identify block" for the disk, and
// then send it to the ao486 ATA/IDE module. 
void init_ide(const char *filename, uint32_t hd_base) {
    uint32_t hd_cylinders;
    uint16_t hd_heads;
    uint16_t hd_spt;
    uint32_t hd_total_sectors;

    FILE *f = fopen(filename, "rb");
    fseek(f, 0, SEEK_END);
    uint64_t size = ftell(f) - hd_base;
    fseek(f, hd_base, SEEK_SET);
    uint8_t mbr[512];
    fread(mbr, 1, 512, f);
    fclose(f);

    calc_geometry(mbr, &hd_cylinders, &hd_heads, &hd_spt, size);
    hd_total_sectors = hd_cylinders * hd_heads * hd_spt;

	unsigned int identify[256] = {
		0x0040, 										//word 0
		(hd_cylinders > 16383)? 16383 : hd_cylinders, 	//word 1
		0x0000,											//word 2 reserved
		hd_heads,										//word 3
		(unsigned short)(512 * hd_spt),					//word 4
		512,											//word 5
		hd_spt,											//word 6
		0x0000,											//word 7 vendor specific
		0x0000,											//word 8 vendor specific
		0x0000,											//word 9 vendor specific
		('A' << 8) | 'O',								//word 10
		('H' << 8) | 'D',								//word 11
		('0' << 8) | '0',								//word 12
		('0' << 8) | '0',								//word 13
		('0' << 8) | ' ',								//word 14
		(' ' << 8) | ' ',								//word 15
		(' ' << 8) | ' ',								//word 16
		(' ' << 8) | ' ',								//word 17
		(' ' << 8) | ' ',								//word 18
		(' ' << 8) | ' ',								//word 19
		3,   											//word 20 buffer type
		512,											//word 21 cache size
		4,												//word 22 number of ecc bytes
		0,0,0,0,										//words 23..26 firmware revision
		('A' << 8) | 'O',								//words 27..46 model number
		(' ' << 8) | 'H',
		('a' << 8) | 'r',
		('d' << 8) | 'd',
		('r' << 8) | 'i',
		('v' << 8) | 'e',
		(' ' << 8) | ' ',
		(' ' << 8) | ' ',
		(' ' << 8) | ' ',
		(' ' << 8) | ' ',
		(' ' << 8) | ' ',
		(' ' << 8) | ' ',
		(' ' << 8) | ' ',
		(' ' << 8) | ' ',
		(' ' << 8) | ' ',
		(' ' << 8) | ' ',
		(' ' << 8) | ' ',
		(' ' << 8) | ' ',
		(' ' << 8) | ' ',
		(' ' << 8) | ' ',
		16,												//word 47 max multiple sectors
		1,												//word 48 dword io
		1<<9,											//word 49 lba supported
		0x0000,											//word 50 reserved
		0x0200,											//word 51 pio timing
		0x0200,											//word 52 pio timing
		0x0007,											//word 53 valid fields
		(hd_cylinders > 16383)? 16383 : hd_cylinders, 	//word 54
		hd_heads,										//word 55
		hd_spt,											//word 56
		hd_total_sectors & 0xFFFF,						//word 57
		hd_total_sectors >> 16,							//word 58
		0x0000,											//word 59 multiple sectors
		hd_total_sectors & 0xFFFF,						//word 60
		hd_total_sectors >> 16,							//word 61
		0x0000,											//word 62 single word dma modes
		0x0000,											//word 63 multiple word dma modes
		0x0000,											//word 64 pio modes
		120,120,120,120,								//word 65..68
		0,0,0,0,0,0,0,0,0,0,0,							//word 69..79
		0x007E,											//word 80 ata modes
		0x0000,											//word 81 minor version number
		1<<14,  										//word 82 supported commands
		(1<<14) | (1<<13) | (1<<12) | (1<<10),			//word 83
		1<<14,	    									//word 84
		1<<14,	 	    								//word 85
		(1<<14) | (1<<13) | (1<<12) | (1<<10),			//word 86
		1<<14,	    									//word 87
		0x0000,											//word 88
		0,0,0,0,										//word 89..92
		1 | (1<<14) | 0x2000,							//word 93
		0,0,0,0,0,0,									//word 94..99
		hd_total_sectors & 0xFFFF,						//word 100
		hd_total_sectors >> 16,							//word 101
		0,												//word 102
		0,												//word 103

		0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,//word 104..127

		0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,				//word 128..255
		0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
		0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
		0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
		0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
		0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
		0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
		0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
	};

    /*
	0x00.[31:0]:    identify write
	0x01.[16:0]:    media cylinders
	0x02.[4:0]:     media heads
	0x03.[8:0]:     media spt
	0x04.[13:0]:    media sectors per cylinder = spt * heads
	0x05.[31:0]:    media sectors total
	0x06.[31:0]:    media sd base
	*/
    ensure_posedge();      // make sure clk=0
    printf("IDE: write identify\n");
    for (int i = 0; i < 128; i++) {
        tb.mgmt_write = 1;
        tb.mgmt_address = 0xF000;    // set CMOS_DISKETTE register
        tb.mgmt_writedata = ((unsigned int)identify[2*i+1] << 16) | (unsigned int)identify[2*i+0];
        full_step();
    }

    tb.mgmt_address = 0xF001;
    tb.mgmt_writedata = hd_cylinders;
    full_step();

    tb.mgmt_address = 0xF002;    
    tb.mgmt_writedata = hd_heads;
    full_step();

    tb.mgmt_address = 0xF003;   
    tb.mgmt_writedata = hd_spt; 
    full_step();
                                
    tb.mgmt_address = 0xF004;   
    tb.mgmt_writedata = (uint32_t)hd_spt * hd_heads; 
    full_step();

    tb.mgmt_address = 0xF005;   
    tb.mgmt_writedata = (uint32_t)hd_spt * hd_heads * hd_cylinders; 
    full_step();

    // use default SD base (256 sectors, i.e. after BIOS and VGA BIOS)
    // tb.mgmt_address = 0xF006;   
    // tb.mgmt_writedata = 0;      // SD base is set to 0
    // step(); step();

    tb.mgmt_write = 0;

    full_step();
}
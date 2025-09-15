// ao486-sim: x86 whole-system simulator
//
// This is a Verilator-based simulator for the ao486 CPU core.
// It simulates the entire x86 system, including the CPU, memory,
// and peripherals.
//
// nand2mario, 7/2025
//
#include "verilated.h"
#include "verilated_fst_c.h"
#include "Vsystem.h"
#include "Vsystem_ao486.h"
#include "Vsystem_system.h"
#include "Vsystem__Syms.h"
#include "Vsystem_pipeline.h"
#include "Vsystem_driver_sd.h"
#include <svdpi.h>
#include <fstream>
#include <iostream>
#include <set>
#include <map>
#include <vector>
#include <sys/stat.h>
#include <SDL.h>
#include <chrono>

#include "ide.h"
#include "wav_writer.h"

using namespace std;

const int H_RES = 720;    // VGA text mode is 720x400
const int V_RES = 480;    // graphics mode is max 640x480
int resolution_x = 720;
int resolution_y = 400;
int x_cnt, y_cnt;
int frame_count = 0;
string disk_file;
typedef struct Pixel
{			   // for SDL texture
	uint8_t a; // transparency
	uint8_t b; // blue
	uint8_t g; // green
	uint8_t r; // red
} Pixel;

Pixel screenbuffer[H_RES * V_RES];

bool trace_toggle = false;
void set_trace(bool toggle);
bool trace_vga = false;
bool trace_ide = false;
bool trace_post = false;
bool trace_sound = false;
bool trace_symbols = false;
bool record_audio = false;
string symbols_file;
map<uint32_t, string> symbols;
uint64_t sim_time = 0;
uint64_t last_time;
uint64_t start_time = UINT64_MAX;
uint64_t stop_time = UINT64_MAX;
Vsystem tb;
VerilatedFstC* trace;
int failure = -1;
uint16_t ignore_mask = 0xf400;      // 15:12 
int ignore_memory = 0;
set<uint32_t> watch_memory;         // dword addresses
bool mem_write_r = 0;
uint32_t eip_r = 0;

// FPS tracking variables (wall clock time)
uint32_t fps_start_time = 0;
uint32_t fps_frame_count = 0;

// Headless mode toggle
bool g_headless = false;

static inline uint32_t get_ticks_ms() {
    if (!g_headless) return SDL_GetTicks();
    using clock = std::chrono::steady_clock;
    static auto t0 = clock::now();
    auto diff = std::chrono::duration_cast<std::chrono::milliseconds>(clock::now() - t0).count();
    return static_cast<uint32_t>(diff);
}

#include "scancode.h"

bool posedge;
void step() {
    posedge = false;
    // tb.clk_sys = !tb.clk_sys;
    // tb.clk_vga = tb.clk_sys;
    tb.clk_vga = !tb.clk_vga;                   // clk_vga is 50Mhz
    if (tb.clk_vga) {
        tb.clk_sys = !tb.clk_sys;               // clk_sys is 25Mhz
        posedge = tb.clk_sys;
        tb.clk_audio = tb.clk_sys;              // should be 24.576Mhz, 25Mhz is close enough
    }
    tb.eval();
    sim_time++;
    if (trace_toggle) {
        trace->dump(sim_time);
    }
}

// Simulate a full clk_sys cycle (4 steps)
void full_step() {
    step(); step();
    step(); step();
}

// Advance time until posedge of clk_sys
void ensure_posedge() {
    while (!posedge) {
        step();
    }
}

/*
inline void set_cmos(uint8_t addr, uint8_t data) {
    tb.mgmt_write = 1;
    tb.mgmt_address = 0xF400 + addr;
    tb.mgmt_writedata = data;
    full_step();
    tb.mgmt_write = 0;
}

void init_cmos() {
    ensure_posedge();      // make sure clk=0

    int XMS_KB = 1024;     // 2MB of total memory
    set_cmos(0x30, XMS_KB & 0xff);
    set_cmos(0x31, (XMS_KB >> 8) & 0xff);

    set_cmos(0x14, 0x01);  // EQUIP byte: diskette exists
    set_cmos(0x10, 0x20);  // 1.2MB 5.25 drive

    set_cmos(0x09, 0x24);  // year in BCD
    set_cmos(0x08, 0x01);  // month
    set_cmos(0x07, 0x01);  // day of month
    set_cmos(0x32, 0x20);  // century

    full_step();
}
    */


bool cpu_io_write_do_r = 0;
bool cpu_io_read_do_r = 0;
bool cpu_io_read_done_r = 0;
uint16_t int10h_ip_r = 0;
uint8_t crtc_reg = 0;
bool blank_n_r = 0;
bool bios_dbg_active = true;   // for BX_VIRTUAL_PORTS output on port 0x8888
bool irq5_r = 0;
bool irq7_r = 0;

// WAV file recording
static WAVWriter* wav_writer = nullptr;
static int audio_sample_counter = 0;
static const int AUDIO_SAMPLE_RATE = 48000;
static const int CLK_AUDIO_FREQ = 25000000;  // 25MHz (close to 24.576MHz)
static const int SAMPLE_DIVISOR = 512;  // Approximately 48kHz from 25MHz clock

void print_ide_trace() {
    // print IDE I/O writes and reads
    if (trace_ide && tb.system->cpu_io_write_do && !cpu_io_write_do_r && 
        (tb.system->cpu_io_write_address >= 0x1f0 && tb.system->cpu_io_write_address <= 0x1f7 ||
         tb.system->cpu_io_write_address >= 0x170 && tb.system->cpu_io_write_address <= 0x177)) {
        printf("%8lld: IDE [%04x]=%02x, EIP=%08x\n", sim_time, tb.system->cpu_io_write_address, tb.system->cpu_io_write_data & 0xff,
                tb.system->ao486->exe_eip);
    }
    // if (trace_ide && tb.system->cpu_io_read_do && !cpu_io_read_do_r && 
    //     (tb.system->cpu_io_read_address >= 0x1f0 && tb.system->cpu_io_read_address <= 0x1f7 ||
    //      tb.system->cpu_io_read_address >= 0x170 && tb.system->cpu_io_read_address <= 0x177)) {
    //     printf("%8lld: IDE read %04x, EIP=%08x\n", sim_time, tb.system->cpu_io_read_address,
    //             tb.system->ao486->eip);
    // }
}

void print_sound_trace() {
    // print Sound Blaster I/O writes (0x220-0x230 range)
    if (trace_sound && tb.system->cpu_io_write_do && !cpu_io_write_do_r && 
        tb.system->cpu_io_write_address >= 0x220 && tb.system->cpu_io_write_address <= 0x230) {
        const char* port_name = "";
        switch (tb.system->cpu_io_write_address) {
            case 0x220: port_name = " (FM Left)"; break;
            case 0x221: port_name = " (FM Right)"; break;
            case 0x222: port_name = " (FM Status/Timer)"; break;
            case 0x223: port_name = " (FM Timer)"; break;
            case 0x224: port_name = " (Mixer Index)"; break;
            case 0x225: port_name = " (Mixer Data)"; break;
            case 0x226: port_name = " (DSP Reset)"; break;
            case 0x228: port_name = " (FM Status)"; break;
            case 0x229: port_name = " (FM Register)"; break;
            case 0x22A: port_name = " (DSP Read Data)"; break;
            case 0x22C: port_name = " (DSP Write Data/Command)"; break;
            case 0x22E: port_name = " (DSP Data Available)"; break;
            case 0x22F: port_name = " (DSP IRQ 16-bit)"; break;
        }
        printf("%8lld: SB_WR [%04x]=%02x%s, EIP=%08x\n", sim_time, tb.system->cpu_io_write_address, 
                tb.system->cpu_io_write_data & 0xff, port_name, tb.system->ao486->exe_eip);
    }
    
    // print Sound Blaster I/O reads (0x220-0x230 range)
    if (trace_sound && tb.system->cpu_io_read_done && !cpu_io_read_done_r && 
        tb.system->cpu_io_read_address >= 0x220 && tb.system->cpu_io_read_address <= 0x230) {
        const char* port_name = "";
        switch (tb.system->cpu_io_read_address) {
            case 0x220: port_name = " (FM Left)"; break;
            case 0x221: port_name = " (FM Right)"; break;
            case 0x222: port_name = " (FM Status/Timer)"; break;
            case 0x224: port_name = " (Mixer Index)"; break;
            case 0x225: port_name = " (Mixer Data)"; break;
            case 0x228: port_name = " (FM Status)"; break;
            case 0x22A: port_name = " (DSP Read Data)"; break;
            case 0x22C: port_name = " (DSP Write Status)"; break;
            case 0x22E: port_name = " (DSP Data Available)"; break;
            case 0x22F: port_name = " (DSP IRQ 16-bit)"; break;
        }
        printf("%8lld: SB_RD [%04x]=%02x%s, EIP=%08x\n", sim_time, tb.system->cpu_io_read_address, 
                tb.system->cpu_io_read_data & 0xff, port_name, tb.system->ao486->exe_eip);
    }
    
    // Monitor Sound Blaster IRQ lines (IRQ 5 and IRQ 7)
    if (trace_sound) {
        bool irq5 = tb.system->irq_5;
        bool irq7 = tb.system->irq_7;
        
        // Print IRQ 5 state changes
        if (irq5 != irq5_r) {
            printf("%8lld: SB_IRQ5 %s, EIP=%08x\n", sim_time, irq5 ? "ASSERTED" : "CLEARED", 
                    tb.system->ao486->exe_eip);
            irq5_r = irq5;
        }
        
        // Print IRQ 7 state changes
        if (irq7 != irq7_r) {
            printf("%8lld: SB_IRQ7 %s, EIP=%08x\n", sim_time, irq7 ? "ASSERTED" : "CLEARED", 
                    tb.system->ao486->exe_eip);
            irq7_r = irq7;
        }
    }
}

void print_vga_trace() {
    // print video I/O writes
    if (trace_vga && tb.system->cpu_io_write_do && !cpu_io_write_do_r && 
        // tb.system->cpu_io_write_address >= 0x3b0 && tb.system->cpu_io_write_address <= 0x3df) {
        (tb.system->cpu_io_write_address == 0x3c9 || tb.system->cpu_io_write_address == 0x3c8)) {
        printf("%8lld: VIDEO [%04x]=%02x, EIP=%08x\n", sim_time, tb.system->cpu_io_write_address, tb.system->cpu_io_write_data & 0xff,
                tb.system->ao486->exe_eip);
    }
    // print CRTC reg writes
    uint32_t eax = tb.system->ao486->pipeline_inst->eax;
    if (trace_vga && tb.system->cpu_io_write_do && !cpu_io_write_do_r && tb.system->cpu_io_write_address == 0x3d4 ) {
        crtc_reg = tb.system->cpu_io_write_data & 0xff;
        if (tb.system->cpu_io_write_length >= 2) {
            printf("%8lld: CRTC [%02x]=%02x, EIP=%08x, EAX=%08x\n", sim_time, crtc_reg, (tb.system->cpu_io_write_data >> 8) & 0xff, tb.system->ao486->exe_eip, eax);
        }
    }
    if (trace_vga && tb.system->cpu_io_write_do && !cpu_io_write_do_r && tb.system->cpu_io_write_address == 0x3d5) {
        printf("%8lld: CRTC [%02x]=%02x, EIP=%08x, EAX=%08x\n", sim_time, crtc_reg, tb.system->cpu_io_write_data & 0xff, 
                tb.system->ao486->exe_eip, eax);
    }

    // print int 10h calls
    // if (trace_vga && tb.system->ao486->pipeline_inst->ex_opcode == 0xCD && tb.system->ao486->pipeline_inst->ex_imm == 0x10 &&
    //     tb.system->ao486->pipeline_inst->ex_valid && tb.system->ao486->pipeline_inst->ex_ready &&
    //     tb.system->ao486->pipeline_inst->ex_ip_after != int10h_ip_r) {
    //     int10h_ip_r = tb.system->ao486->pipeline_inst->
    //     printf("%8lld: INT 10h, EIP=%08x\n", sim_time, tb.system->ao486->eip);
    // }
    // if (tb.system->u_z86->ex_ip_after != int10h_ip_r) {
    //     int10h_ip_r = 0;   // clear int10 IP when CPU moves on to new instruction
    // }
}

void print_symbol_trace() {
    if (trace_symbols && tb.system->ao486->exe_eip != eip_r) {
        eip_r = tb.system->ao486->exe_eip;
        uint32_t cs = tb.system->ao486->pipeline_inst->cs;
        // EIP points to next instruction, so search for previous 8 bytes for symbol
        uint32_t addr = cs*16+eip_r;
        if (symbols.find(addr) != symbols.end()) {
            printf("%8lld: %-20s CS:IP=%05x SP=%04x\n", sim_time, symbols[addr].c_str(), addr, 
                    tb.system->ao486->pipeline_inst->esp);
        }
    }
}

uint8_t read_byte(uint32_t addr) {
    // Access SDRAM model array (flattened) inside Vsystem_system
    uint16_t w = tb.system->sdram__DOT__mem[addr >> 1];
    return (w >> (8 * (addr & 1))) & 0xff;
}

uint16_t read_word(uint32_t addr) {
    return  read_byte(addr) + 
            ((uint16_t)read_byte(addr+1) << 8);
}

uint32_t read_dword(uint32_t addr) {
    return  read_byte(addr) + 
            ((uint32_t)read_byte(addr+1) << 8) + 
            ((uint32_t)read_byte(addr+2) << 16) + 
            ((uint32_t)read_byte(addr+3) << 24);
}

string read_string(uint32_t addr) {
    string r;
    for (;;) {
        char c = read_byte(addr++);
        if (!c) return r;
        r += c;
    }
}

// sp points to 1st argument after format string
void bios_printf(const string fmt, uint32_t sp, uint32_t ds, uint32_t ss) {
    for (int i = 0; i < fmt.size(); i++) {
        uint16_t arg;
        uint16_t argu;
        string str;
        char c = fmt[i];
        if (c == '%' && i+1 < fmt.size()) {
            int j = i + 1;
            // Parse width and zero-padding, e.g. %02x, %04x
            char fmtbuf[16] = "%";
            int fmtlen = 1;
            // Parse flags (only '0' supported)
            bool has_zero = false;
            if (fmt[j] == '0') {
                has_zero = true;
                fmtbuf[fmtlen++] = '0';
                j++;
            }
            // Parse width (1 or 2 digits)
            int width = 0;
            while (j < fmt.size() && isdigit(fmt[j])) {
                width = width * 10 + (fmt[j] - '0');
                fmtbuf[fmtlen++] = fmt[j];
                j++;
            }
            // Parse type
            if (j < fmt.size()) {
                char type = fmt[j];
                fmtbuf[fmtlen++] = type;
                fmtbuf[fmtlen] = 0;
                switch (type) {
                    case 's':
                    case 'S':
                        arg = read_word(ss*16+sp);
                        sp+=2;
                        str = read_string(ds*16+arg);
                        printf("%s", str.c_str());
                        break;
                    case 'c':
                        c = read_byte(ss*16+sp);
                        sp++;
                        printf("%c", c);
                        break;
                    case 'x':
                    case 'X':
                    case 'u':
                    case 'd':
                    {
                        argu = read_word(ss*16+sp);
                        sp+=2;
                        // For 'd', cast to int for signed printing
                        if (type == 'd')
                            printf(fmtbuf, argu & 0x8000 ? argu - 0x10000 : argu);
                        else
                            printf(fmtbuf, argu);
                        break;
                    }
                    default:
                        // Print unknown format as literal
                        printf("%%%c", type);
                }
                i = j;
            } else {
                // Malformed format, print as literal
                printf("%%");
            }
        } else
            printf("%c", c);
    }
}

void usage() {
    printf("\nUsage: Vsystem [--trace] [--headless] [-s T0] [-e T1] <sdcard.img>\n");
    printf("  -s T0     start tracing at time T0\n");
    printf("  -e T1     stop simulation at time T1\n");
    printf("  --trace   start trace immediately\n");
    printf("  --vga     print VGA related operations\n");
    printf("  --ide     print ATA/IDE related operations\n");
    printf("  --sound   print Sound Blaster related operations\n");
    printf("  --record  record DSP audio output to dsp.wav\n");
    printf("  --post    print POST codes\n");
    printf("  --mem <addr> watch memory location\n");
    printf("  --symbols <file> print symbols reached by EIP\n");
    printf("  --headless        run without creating an SDL window\n");
    printf("\nSD card image layout:\n");
    printf("  offset 0:     boot0.rom (BIOS, 64KB)\n");
    printf("  offset 64KB:  boot1.rom (VGA BIOS, 32KB)\n");
    printf("  offset 128KB: disk image\n");
}

void load_disk(const char *fname);
void persist_disk();

void load_symbols() {
    if (symbols_file.empty()) return;
    ifstream file(symbols_file);
    string line;
    auto parse_addr = [](const string& addr_str) -> uint32_t {
        uint32_t addr;
        if (addr_str.find(':') != string::npos) {
            addr = stoul(addr_str.substr(0, addr_str.find(':')), nullptr, 16);
            addr <<= 4;
            addr += stoul(addr_str.substr(addr_str.find(':')+1), nullptr, 16);
        } else {
            addr = stoul(addr_str, nullptr, 16);
        }
        return addr;
    };
    while (getline(file, line)) {
        istringstream iss(line);
        string addr_str, addr_str2, symbol;
        if (iss >> addr_str >> addr_str2 >> symbol) {
            try {
                // addr_str is in format F000:0000 or F0000
                uint32_t addr = parse_addr(addr_str);
                uint32_t addr2 = parse_addr(addr_str2);
                symbols[addr2] = symbol;      // we match against the 2nd address
            } catch (const invalid_argument& e) {
                printf("Invalid symbol address: %s\n", addr_str.c_str());
            }
        }
    }
    printf("Loaded %d symbols from %s\n", (int)symbols.size(), symbols_file.c_str());
    int i = 0;
    for (auto& [addr, symbol] : symbols) {
        printf("%08x: %s\n", addr, symbol.c_str());
        if (i++ > 10) break;
    }
    file.close();
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    if (argc < 1+1) {
        usage();
        return 1;
    }

    for (int i = 1; i < argc; i++) {
        string arg(argv[i]);
        if (arg == "-s") {
            start_time = atoi(argv[++i]);
        } else if (arg == "-e") {
            stop_time = atoi(argv[++i]);
        } else if (arg == "--trace") {
            set_trace(true);
        } else if (arg == "--headless") {
            g_headless = true;
        } else if (arg == "--vga") {
            trace_vga = true;
        } else if (arg == "--post") {
            trace_post = true;
        } else if (arg == "--ide") {
            trace_ide = true;
        } else if (arg == "--sound") {
            trace_sound = true;
        } else if (arg == "--record") {
            record_audio = true;
        } else if (arg == "--mem") {
            // Support decimal or hex (0x...) addresses
            watch_memory.insert(strtol(argv[++i], nullptr, 0) >> 2);
        } else if (arg == "--symbols") {
            symbols_file = argv[++i];
            load_symbols();
            trace_symbols = true;
        } else if (arg[0] == '-') {
            printf("Unknown option: %s\n", argv[i]);
            return 1;
        } else {
            disk_file = argv[i];
            break;
        }
    }
    
    if (disk_file.empty()) {
        usage();
        return 1;
    }

    SDL_Window *sdl_window = NULL;
    SDL_Renderer *sdl_renderer = NULL;
    SDL_Texture *sdl_texture = NULL;

    if (!g_headless) {
        if (SDL_Init(SDL_INIT_VIDEO) < 0) {
            printf("SDL init failed.\n");
            return 1;
        }
        sdl_window = SDL_CreateWindow("z86 sim", SDL_WINDOWPOS_CENTERED,
                                      SDL_WINDOWPOS_CENTERED, 800, 600, SDL_WINDOW_SHOWN);
        if (!sdl_window) {
            printf("Window creation failed: %s\n", SDL_GetError());
            return 1;
        }
        sdl_renderer = SDL_CreateRenderer(sdl_window, -1,
                                          SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
        if (!sdl_renderer) {
            printf("Renderer creation failed: %s\n", SDL_GetError());
            return 1;
        }
        sdl_texture = SDL_CreateTexture(sdl_renderer, SDL_PIXELFORMAT_RGBA8888,
                                        SDL_TEXTUREACCESS_TARGET, H_RES, V_RES);
        if (!sdl_texture) {
            printf("Texture creation failed: %s\n", SDL_GetError());
            return 1;
        }

        SDL_UpdateTexture(sdl_texture, NULL, screenbuffer, H_RES * sizeof(Pixel));
        SDL_RenderClear(sdl_renderer);
        SDL_RenderCopy(sdl_renderer, sdl_texture, NULL, NULL);
        SDL_RenderPresent(sdl_renderer);
        SDL_StopTextInput(); // for SDL_KEYDOWN
    } else {
        printf("Headless mode: SDL disabled.\n");
    }

    printf("Starting simulation\n");

    // Initialize WAV writer for DSP output capture (if requested)
    if (record_audio) {
        wav_writer = new WAVWriter("dsp.wav", AUDIO_SAMPLE_RATE, 2, 16);
        printf("Recording DSP output to dsp.wav at %d Hz\n", AUDIO_SAMPLE_RATE);
    }

    tb.clock_rate = 25000000;            // for time keeping of timer, RTC and floppy
    tb.clock_rate_vga = 50000000;        // >= max VGA pixel clock (28.3Mhz)
    ensure_posedge();
    // reset whole system
    tb.reset = 1;
    full_step();

    // CMOS and IDE init are now done in system.sv
    // set amount of extended memory and date / time
    // init_cmos();
    // set HDD geometry and other parameters
    // init_ide(disk_file.c_str(), 256*512);    // Hard disk MBR is at sector 256 

    // load disk image into drive_sd_sim.sv
    load_disk(disk_file.c_str());  
    printf("C++ peek sd_buf[0..15]: ");
    for (int i = 65536; i < 65536+16; ++i) {
        printf("%02x ", tb.system->driver_sd->sd_buf[i]);
    }
    printf("\n");    

    // now release system reset - CPU will be released by boot loader when BIOS loading is complete
    tb.reset = 0;

    bool vsync_r = 0;
    int x = 0;
    int y = 0;
    bool speaker_out_r = 0;
    bool speaker_active = false;

    bool post_need_newline = false;
    int pix_cnt = 0;
	vector<uint8_t> scancode;   // scancode
	uint64_t last_scancode_time;
    SDL_Keycode last_key = 0;

    while (sim_time < stop_time) {
        step();

        // watch memory locations
        if (watch_memory.size() > 0) {
            if (posedge && tb.system->avm_write && !mem_write_r && watch_memory.find(tb.system->avm_address) != watch_memory.end()) {
                printf("%8lld: WRITE [%08x]=%08x, BE=%1x, EIP=%08x\n", sim_time, tb.system->avm_address << 2, tb.system->avm_writedata,
                        tb.system->avm_byteenable, tb.system->ao486->exe_eip);
            }
            mem_write_r = tb.system->avm_write;
        }

        if (trace_ide)
            print_ide_trace();

        if (trace_sound)
            print_sound_trace();

        if (trace_vga)
            print_vga_trace();

        if (trace_symbols) {
            print_symbol_trace();
        }

        // detect speaker output
        if (tb.speaker_out != speaker_out_r) {
            speaker_active = true;
        }
        speaker_out_r = tb.speaker_out;

        // Capture Bochs BIOS debug (BX_VIRTUAL_PORTS) on port 0x8888
        if (tb.system->cpu_io_write_do && !cpu_io_write_do_r && tb.system->cpu_io_write_address == 0x8888) {
            uint8_t ch = tb.system->cpu_io_write_data & 0xFF;
            printf("\033[33m"); // start yellow color
            putchar(ch);
            printf("\033[0m"); // reset color and newline
        }
        if (tb.system->cpu_io_write_do && !cpu_io_write_do_r && tb.system->cpu_io_write_address == 0x190) {
            uint8_t code = tb.system->cpu_io_write_data & 0xFF;
            printf("\033[35m"); // start purple color
            printf("POST: %02x\n", code);
            printf("\033[0m"); // reset color and newline
        }        
        cpu_io_write_do_r = tb.system->cpu_io_write_do;
        cpu_io_read_do_r = tb.system->cpu_io_read_do;
        cpu_io_read_done_r = tb.system->cpu_io_read_done;

        // Sample DSP audio output every SAMPLE_DIVISOR clk_audio cycles
        if (posedge) {
            audio_sample_counter++;
            if (audio_sample_counter >= SAMPLE_DIVISOR) {
                audio_sample_counter = 0;
                
                // Get Sound Blaster DSP output samples
                // Access the Sound Blaster DSP output directly from system ports
                int16_t sample_l = (int16_t)tb.sample_sb_l;
                int16_t sample_r = (int16_t)tb.sample_sb_r;
                
                if (wav_writer) {
                    wav_writer->writeSample(sample_l, sample_r);
                }
            }
        }

        // Trace int 10h (Eh) to print character
        if (tb.system->ao486->exe_eip == 0xA58 && eip_r != 0xA58 && tb.system->ao486->pipeline_inst->cs == 0xC000) {
            uint32_t eax = tb.system->ao486->pipeline_inst->eax;
            if ((eax >> 8 & 0xFF) == 0xE) {
                if (sim_time - last_time > 1e5) {
                    printf("%8lld: PRINT: ", sim_time);
                }
                printf("\033[32m%c\033[0m", eax & 0xFF);
                last_time = sim_time;
            }
        }
        // Trace int 13h disk accesses
        if (tb.system->ao486->exe_eip == 0x85d3 && eip_r != 0x85d3 && tb.system->ao486->pipeline_inst->cs == 0xF000) {
            uint32_t eax = tb.system->ao486->pipeline_inst->eax;
            uint32_t ecx = tb.system->ao486->pipeline_inst->ecx;
            uint32_t edx = tb.system->ao486->pipeline_inst->edx;
            int cylinder = (ecx >> 8 & 0xFF) + ((ecx & 0xC0) << 2);
            int head = edx >> 8 & 0xFF;
            int sector = ecx & 0x3F;
            int count = eax & 0xFF;
            printf("%8lld: INT 13h: AX=%04x, CX=%04x, DX=%04x", sim_time, eax & 0xFFFF, ecx & 0xFFFF, edx & 0xFFFF);
            printf(", C/H/S = %d/%d/%d, count=%d\n", cylinder, head, sector, count);
        }
        // Trace int 15h memory size detection
        if (tb.system->ao486->exe_eip == 0xf85c && eip_r != 0xf85c && tb.system->ao486->pipeline_inst->cs == 0xF000) {
            uint32_t eax = tb.system->ao486->pipeline_inst->eax;
            uint32_t ecx = tb.system->ao486->pipeline_inst->ecx;
            uint32_t edx = tb.system->ao486->pipeline_inst->edx;
            printf("%8lld: INT 15h: AX=%04x, CX=%04x, DX=%04x\n", sim_time, eax & 0xFFFF, ecx & 0xFFFF, edx & 0xFFFF);
        }
        eip_r = tb.system->ao486->exe_eip;

        // Capture video frame
        if (tb.clk_vga && tb.video_ce) {
            if (tb.video_vsync && !vsync_r) {
                x = 0; y = 0;
                x_cnt++; y_cnt++;
                printf("%8lld: VSYNC: pix_cnt=%d, width=%d, height=%d, speaker=%s, CS:IP=%04x:%04x\n", sim_time, pix_cnt, x_cnt, y_cnt, speaker_active ? "ON" : "OFF", 
                        tb.system->ao486->pipeline_inst->cs, tb.system->ao486->exe_eip);

                // detect video resolution change
                const vector<pair<int,int>> resolutions = 
                    {{720,400}, {360,400}, {640,344},                                    // text modes
                     {640,480}, {640,400}, {640,200}, {640,350}, {320,200}, {320,240}};  // graphics modes
                if ((x_cnt != resolution_x || y_cnt != resolution_y) && 
                       find(resolutions.begin(), resolutions.end(), pair<int,int>{x_cnt, y_cnt}) != resolutions.end()) {
                    printf("New video resolution: %d x %d\n", x_cnt, y_cnt);
                    resolution_x = x_cnt;
                    resolution_y = y_cnt;
                }

                pix_cnt = 0; x_cnt = 0; y_cnt = 0;
                speaker_active = false;
                
                // FPS calculation using wall clock time
                if (!g_headless && fps_frame_count == 0) {
                    fps_start_time = get_ticks_ms();
                }
                fps_frame_count++;
                
                // Display FPS every 10 frames
                if (!g_headless && fps_frame_count % 10 == 0) {
                    uint32_t current_time = get_ticks_ms();
                    uint32_t elapsed_ms = current_time - fps_start_time;
                    double fps = (double)fps_frame_count / (elapsed_ms / 1000.0);
                    printf("%8lld: FPS: %.2f (frames=%d, time=%.3fs)\n", sim_time, fps, fps_frame_count, elapsed_ms / 1000.0);
                }
                
                // update texture once per frame (in blanking)
                if (!g_headless) {
                    SDL_UpdateTexture(sdl_texture, NULL, screenbuffer, H_RES * sizeof(Pixel));
                    SDL_RenderClear(sdl_renderer);
                    const SDL_Rect srcRect = {0, 0, resolution_x, resolution_y};
                    SDL_RenderCopy(sdl_renderer, sdl_texture, &srcRect, NULL);
                    SDL_RenderPresent(sdl_renderer);
                    SDL_SetWindowTitle(sdl_window, ("ao486 sim - frame " + to_string(frame_count) + (trace_toggle ? " tracing" : "") + (speaker_active ? " speaker" : "")).c_str());
                }
                frame_count++;
            } else if (!tb.video_blank_n) {
                x=0;
                if (blank_n_r) y++;
            } else {
                if (y < V_RES && x < H_RES) {
                    Pixel *p = &screenbuffer[y * H_RES + x];
                    p->a = 0xff;
                    p->r = tb.video_r;
                    p->g = tb.video_g;
                    p->b = tb.video_b;
                    if (p->r || p->g || p->b) {
                        // printf("Pixel at %d,%d\n", x, y);
                        pix_cnt++;
                    }
                    x_cnt = max(x_cnt, x);
                    y_cnt = max(y_cnt, y);
                }
                x++;
            }
            blank_n_r = tb.video_blank_n;
            vsync_r = tb.video_vsync;
        }

        // start / stop tracing
        if (sim_time == start_time) {
            set_trace(true);
        }
        if (sim_time == stop_time) {
            set_trace(false);
        }

        // process SDL events
        if (!g_headless && sim_time % 100 == 0) {
            SDL_Event e;
            if (SDL_PollEvent(&e)) {
                if (e.type == SDL_QUIT) {
                    break;
                }
                if (e.type == SDL_WINDOWEVENT) {
                    if (e.window.event == SDL_WINDOWEVENT_CLOSE) {
                        if (e.window.windowID == SDL_GetWindowID(sdl_window))
                            break;
                    }
                }
				if (e.type == SDL_KEYDOWN && e.key.keysym.sym != last_key) {
                    if (e.key.keysym.mod & KMOD_LGUI) {
                        if (e.key.keysym.sym == SDLK_t) {
    	    				// press WIN-T to toggle trace
                            set_trace(!trace_toggle);
                        } else if (e.key.keysym.sym == SDLK_s) {
                            // press WIN-S to backup disk content
                            persist_disk();
                        }
                    } else {
                        last_key = e.key.keysym.sym;
                        printf("Key pressed: %d\n", e.key.keysym.sym);
                        if (ps2scancodes.find(e.key.keysym.sym) != ps2scancodes.end()) {
                            scancode.insert(scancode.end(), ps2scancodes[e.key.keysym.sym].first.begin(), ps2scancodes[e.key.keysym.sym].first.end());
                        }
                    }
                }
				if (e.type == SDL_KEYUP) {
                    if (e.key.keysym.mod & KMOD_LGUI) {
                        // nothing
                    } else {
                        last_key = 0;
                        printf("Key up: %d\n", e.key.keysym.sym);
	    				if (ps2scancodes.find(e.key.keysym.sym) != ps2scancodes.end()) {
		    				scancode.insert(scancode.end(), ps2scancodes[e.key.keysym.sym].second.begin(), ps2scancodes[e.key.keysym.sym].second.end());
			    		}
                    }
                }
            }
        }

		// send scancode to ps2_device, one scancode takes about 1ms (we'll wait 2ms)
        if (posedge) {
            if (sim_time - last_scancode_time > 1e5  && !scancode.empty()) {
                printf("%8lld: Sending scancode %d\n", sim_time, scancode.front());
                last_scancode_time = sim_time;
                tb.kbd_data = scancode.front();
                tb.kbd_data_valid = 1;
                scancode.erase(scancode.begin());
            } else {
                tb.kbd_data_valid = 0;
            }

            if (tb.kbd_host_data & 0x100) {
                uint8_t cmd = tb.kbd_host_data & 0xff;
                printf("%8lld: Received keyboard command %d\n", sim_time, cmd);
                tb.kbd_host_data_clear = 1;
                if (cmd == 0xFF) {
                    printf("%8lld: Keyboard reset\n", sim_time);
                    scancode.push_back(0xFA);
                    scancode.push_back(0xAA);
                    last_scancode_time = sim_time;    // 0xFA is sent 1ms later
                } else if (cmd >= 0xF0) {
                    // respond to all commands with an ACK
                    scancode.push_back(0xFA);
                    last_scancode_time = sim_time;    // 0xFA is sent 1ms later
                }
            } else if (tb.kbd_host_data_clear) {
                tb.kbd_host_data_clear = 0;
            }

        }
    }
    printf("Simulation stopped at time %lld\n", sim_time);

    // Cleanup
    if (wav_writer) {
        delete wav_writer;
        wav_writer = nullptr;
    }
    
    if (trace) {
        trace->close();
        delete trace;
    }
    return 0;
}

void set_trace(bool toggle) {
    printf("Tracing %s\n", toggle ? "on" : "off");
    if (toggle) {
        if (!trace) {
            trace = new VerilatedFstC;
            tb.trace(trace, 5);
            Verilated::traceEverOn(true);
            // printf("Tracing to waveform.fst\n");
            trace->open("waveform.fst");    
        }
    }
    trace_toggle = toggle;
}

int disk_size;
// Prototypes generated by Verilator from the exports
extern "C" {
    void sd_write(unsigned addr, const uint8_t data);
}

static svScope sd_scope = nullptr;

// DPI-C call from verilog to load disk image
void load_disk(const char *fname) {
    unsigned blk_sz = 1024;
    struct stat st;
    printf("Loading disk image from %s.\n", fname);
    sd_scope = svGetScopeFromName("TOP.system.driver_sd");
    if (!sd_scope) {
        fprintf(stderr, "ERROR: scope TOP.system.driver_sd not found\n");
        exit(1);
    }    
    svSetScope(sd_scope);

    if (stat(fname, &st) != 0) { perror(fname); return; }
    disk_size = st.st_size;

    FILE* f = fopen(fname, "rb");
    if (!f) { perror(fname); return; }

    std::vector<uint8_t> buf(blk_sz);
    unsigned addr = 0;
    while (addr < disk_size) {
        size_t n = fread(buf.data(), 1,
                         std::min<unsigned>(blk_sz, disk_size - addr), f);
        if (!n) break;
        for (int i = 0; i < n; i++) {
            // if (addr + i < 64) {  // Debug: show first 64 bytes being written
            //     printf("SD_WRITE: addr=%x, data=%02x\n", addr + i, buf[i]);
            // }
            sd_write(addr + i, buf[i]);
        }
        addr += n;
    }
    fclose(f);
    printf("Disk image loaded into driver_sd_sim.v\n");
}

void persist_disk() {
    uint8_t buf[1024];
    printf("Persisting disk image to %s.\n", disk_file.c_str());
    svSetScope(sd_scope);

    if (rename(disk_file.c_str(), (disk_file + ".bak").c_str()) != 0) {
        printf("Failed to rename existing disk image to %s.bak\n", disk_file.c_str());
        return;
    }
    printf("Existing disk image renamed to %s.bak\n", disk_file.c_str());

    // write new disk image
    FILE* f = fopen(disk_file.c_str(), "wb");
    if (!f) {
        printf("Failed to open disk image for writing\n");
        return;
    }
    for (int i = 0; i < disk_size; i += 1024) {
        int n = std::min(1024, disk_size - i);
        for (int j = 0; j < n; j++) {
            buf[j] = tb.system->driver_sd->sd_buf[i+j];
        }
        if (fwrite(buf, 1, n, f) != (size_t)n) {
            printf("Failed to write disk image\n");
            fclose(f);
            return;
        }
    }
    fclose(f);
    printf("Disk image persisted to %s\n", disk_file.c_str());
}

# SD card image created with ../tools/mksdcard.py
SDCARD = sdcard_debug.img

#------------------------------------------------------------------------------
# No user changes needed below this line
#------------------------------------------------------------------------------
VERILATOR = verilator
CFLAGS_SDL=$(shell sdl2-config --cflags) -g -O2 -std=c++17
LIBS_SDL=$(shell sdl2-config --libs) -g
VERILATOR_FLAGS = +1800-2017ext+sv --trace-fst --trace-structs --top-module system --cc --exe --threads 1 --build -CFLAGS "$(CFLAGS_SDL)" -LDFLAGS "$(LIBS_SDL)" -j 0 -Wno-WIDTH -Wno-PINMISSING -Wno-COMBDLY
VERILATOR_INCLUDE = -I../src/ao486
VERILATOR_OPT = -O2
D=../src

# Source files
SOURCES = $D/system.sv $D/ao486/ao486.v $D/ao486/exception.v $D/ao486/global_regs.v \
		  $D/memory/main_memory.sv $D/memory/sdram_sim.v \
		  $D/ao486/memory/avalon_mem.v $D/ao486/memory/icache.v $D/ao486/memory/link_dcacheread.v $D/ao486/memory/link_dcachewrite.v \
		  $D/ao486/memory/memory_read.v $D/ao486/memory/memory_write.v $D/ao486/memory/memory.v \
		  $D/ao486/memory/prefetch_control.v $D/ao486/memory/prefetch_fifo.v $D/ao486/memory/prefetch.v \
		  $D/ao486/memory/tlb.v $D/ao486/memory/tlb_memtype.v $D/ao486/memory/tlb_regs_4way.v \
		  $D/ao486/pipeline/condition.v $D/ao486/pipeline/decode_commands.v $D/ao486/pipeline/decode_prefix.v \
		  $D/ao486/pipeline/decode_ready.v $D/ao486/pipeline/decode_regs.v $D/ao486/pipeline/decode.v \
		  $D/ao486/pipeline/execute_commands.v $D/ao486/pipeline/execute_divide.v $D/ao486/pipeline/execute_multiply.v \
		  $D/ao486/pipeline/execute_offset.v $D/ao486/pipeline/execute_shift.v $D/ao486/pipeline/execute.v \
		  $D/ao486/pipeline/fetch.v $D/ao486/pipeline/microcode_commands.v $D/ao486/pipeline/microcode.v \
		  $D/ao486/pipeline/pipeline.v $D/ao486/pipeline/read_commands.v $D/ao486/pipeline/read_debug.v \
		  $D/ao486/pipeline/read_effective_address.v $D/ao486/pipeline/read_mutex.v $D/ao486/pipeline/read.v $D/ao486/pipeline/read_segment.v \
		  $D/ao486/pipeline/write_commands.v $D/ao486/pipeline/write_debug.v $D/ao486/pipeline/write_register.v \
		  $D/ao486/pipeline/write_stack.v $D/ao486/pipeline/write_string.v $D/ao486/pipeline/write.v \
		  $D/soc/dma.v $D/soc/floppy.v $D/soc/ide.v $D/soc/driver_sd_sim.v $D/soc/iobus.v $D/soc/pic.v $D/soc/pit_counter.v \
		  $D/soc/pit.v $D/soc/ps2.v $D/soc/rtc.v $D/soc/vga.v $D/common/dpram.v $D/common/simple_ram.v \
		  $D/common/simple_fifo.v $D/common/ps2_device.v $D/common/simple_mult.v $D/common/uart_tx_V2.v $D/cache/l1_icache.v \
		  $D/common/synchronizer.sv $D/common/cdc_vector_handshake_continuous.sv \
		  $D/soc/sound/sound.v $D/soc/sound/sound_dsp.v $D/soc/sound/opl3/afifo.v $D/soc/sound/opl3/phase_generator.sv \
		  $D/soc/sound/opl3/mem_simple_dual_port.sv $D/soc/sound/opl3/calc_envelope_shift.sv $D/soc/sound/opl3/operator.sv \
		  $D/soc/sound/opl3/calc_phase_inc.sv $D/soc/sound/opl3/opl3_exp_lut.sv $D/soc/sound/opl3/calc_rhythm_phase.sv \
		  $D/soc/sound/opl3/opl3_log_sine_lut.sv $D/soc/sound/opl3/channels.sv $D/soc/sound/opl3/opl3_pkg.sv \
		  $D/soc/sound/opl3/clk_div.sv $D/soc/sound/opl3/control_operators.sv $D/soc/sound/opl3/dac_prep.sv \
		  $D/soc/sound/opl3/edge_detector.sv $D/soc/sound/opl3/envelope_generator.sv $D/soc/sound/opl3/host_if.sv \
		  $D/soc/sound/opl3/ksl_add_rom.sv $D/soc/sound/opl3/leds.sv $D/soc/sound/opl3/mem_multi_bank_reset.sv \
		  $D/soc/sound/opl3/mem_multi_bank.sv $D/soc/sound/opl3/mem_simple_dual_port_async_read.sv \
		  $D/soc/sound/opl3/pipeline_sr.sv $D/soc/sound/opl3/reset_sync.sv $D/soc/sound/opl3/timer.sv \
		  $D/soc/sound/opl3/timers.sv $D/soc/sound/opl3/tremolo.sv $D/soc/sound/opl3/trick_sw_detection.sv \
		  $D/soc/sound/opl3/vibrato.sv $D/soc/sound/opl3/opl3.sv

# CPP_SOURCES = main.cpp ide.cpp
CPP_SOURCES = main.cpp

# Default target
all: obj_dir/Vsystem

# Generate Verilator files and build
obj_dir/Vsystem: $(SOURCES) $(CPP_SOURCES)
	$(VERILATOR) $(VERILATOR_FLAGS) $(VERILATOR_INCLUDE) $(VERILATOR_OPT) $(SOURCES) $(CPP_SOURCES) 

# Clean generated filesx2
clean:
	rm -rf obj_dir
	rm -f *.o *.d sim_cache

boot: obj_dir/Vsystem $(SDCARD)
	./obj_dir/Vsystem --vga --trace -s 0 -e 3000000 $(SDCARD)

trace: obj_dir/Vsystem $(SDCARD)
	./obj_dir/Vsystem -s 10000000 -e 15000000 $(SDCARD)

sim: obj_dir/Vsystem $(SDCARD)
	./obj_dir/Vsystem $(SDCARD)

test386: obj_dir/Vsystem test386.img
	./obj_dir/Vsystem --headless -s 0 -e 5000000 test386.img

.PHONY: all sim run clean

N=snestang_top
D=../src

GHDL ?= ghdl
GHDL_FLAGS = --std=08 --latches --out=verilog
GHDL_DIR = obj_dir/ghdl
VERILATOR_FLAGS = -Wno-fatal

DSP_VHDL = $D/CEGen.vhd $D/dpram.vhd $D/DSP_PKG.vhd $D/DSP.vhd
SMP_VHDL = $D/SPC700/SPC700_pkg.vhd $D/SPC700/AddrGen.vhd \
	$D/SPC700/AddSub.vhd $D/SPC700/ALU.vhd $D/SPC700/BCDAdj.vhd \
	$D/SPC700/MCode.vhd $D/SPC700/MulDiv.vhd $D/SPC700/SPC700.vhd $D/SMP.vhd
PPU_VHDL = $D/PPU_PKG.vhd $D/PPU.vhd
CPU_VHDL = $D/65C816/P65816_pkg.vhd $D/65C816/BCDAdder.vhd \
	$D/65C816/AddSubBCD.vhd $D/65C816/AddrGen.vhd $D/65C816/ALU.vhd \
	$D/65C816/MCode.vhd $D/65C816/P65C816.vhd

GHDL_SRCS = $(GHDL_DIR)/DSP.v $(GHDL_DIR)/SMP.v $(GHDL_DIR)/SPPU.v \
	$(GHDL_DIR)/CEGen.v $(GHDL_DIR)/P65C816.v
SRCS = $D/verilator/config.v $D/verilator/test_loader.v $D/verilator/sdram_sim.v \
	$D/verilator/dpram.v $D/snestang_top.v $D/cpu.v $D/main.v \
	$D/ppuhoam.v $D/ppuoam.v $D/ppusprbuf.v $D/ppucgram.v \
	$D/chip/DSP/DSP_LHRomMap.v $D/chip/DSP/OBC1.v $D/chip/DSP/SRTC.v $D/chip/DSP/DSPn.v \
	$D/smc_parser.v $D/SNES.v $D/mega138k/vram.v $D/swram.v $(GHDL_SRCS)
#	 $D/chip/GSU/GSU_PKG.v $D/chip/GSU/GSUMap.v $D/chip/GSU/GSU.v 

INCLUDES=-I$D -I$D/spc700 -I$D/65C816

CFLAGS_SDL=$(shell sdl2-config --cflags) -O2
LIBS_SDL=$(shell sdl2-config --libs)

.PHONY: build sim verilate clean gtkwave audio
	
build: ./obj_dir/V$N

verilate: ./obj_dir/V$N.cpp

$(GHDL_DIR):
	mkdir -p $@

$(GHDL_DIR)/DSP.v: $(DSP_VHDL) | $(GHDL_DIR)
	$(GHDL) synth $(GHDL_FLAGS) --vendor-library=work $(DSP_VHDL) -e DSP > $@.tmp
	mv $@.tmp $@

$(GHDL_DIR)/SMP.v: $(SMP_VHDL) | $(GHDL_DIR)
	$(GHDL) synth $(GHDL_FLAGS) $(SMP_VHDL) -e SMP > $@.tmp
	mv $@.tmp $@

$(GHDL_DIR)/SPPU.v: $(PPU_VHDL) | $(GHDL_DIR)
	$(GHDL) synth $(GHDL_FLAGS) $(PPU_VHDL) -e SPPU > $@.tmp
	mv $@.tmp $@

$(GHDL_DIR)/CEGen.v: $D/CEGen.vhd | $(GHDL_DIR)
	$(GHDL) synth $(GHDL_FLAGS) $< -e CEGen > $@.tmp
	mv $@.tmp $@

$(GHDL_DIR)/P65C816.v: $(CPU_VHDL) | $(GHDL_DIR)
	$(GHDL) synth $(GHDL_FLAGS) $(CPU_VHDL) -e P65C816 > $@.tmp
	mv $@.tmp $@

./obj_dir/V$N.cpp: Makefile sim_main.cpp $(SRCS)
	@echo
	@echo "### VERILATE ####"
	mkdir -p obj_dir
	#verilator --top-module $N --trace -cc -O3 --exe -CFLAGS "$(CFLAGS_SDL)" -LDFLAGS "$(LIBS_SDL)" $(INCLUDES) $(SRCS) sim_main.cpp
	verilator $(VERILATOR_FLAGS) --top-module $N --trace-fst -cc -O3 --exe -CFLAGS "$(CFLAGS_SDL)" -LDFLAGS "$(LIBS_SDL)" $(INCLUDES) $(SRCS) sim_main.cpp

./obj_dir/V$N: verilate
	@echo
	@echo "### BUILDING SIM ###"
	make -C obj_dir -f V$N.mk V$N
	cp -a $D/roms obj_dir
	cp -a $D/chip/DSP/*.hex obj_dir
	test -s obj_dir/random_4m_words.hex || hexdump -vn8388608 -e '8/2 "%04x ""\n"' /dev/random > obj_dir/random_4m_words.hex

sim: ./obj_dir/V$N
	@echo
	@echo "### SIMULATION (GUI) ###"
	@cd obj_dir && ./V$N -c 400000000

trace: ./obj_dir/V$N
	@echo
	@echo "### SIMULATION (trace) ###"
	@cd obj_dir && ./V$N -t -c 100000000 2> stderr.log

trace2: ./obj_dir/V$N
	@echo
	@echo "### SIMULATION (trace) ###"
	@cd obj_dir && ./V$N -t -c 3000000000 -s 300000000

gtkwave:
	gtkwave obj_dir/waveform.fst

audio:
	ffmpeg -y -f s16le -ar 32k -ac 2 -i obj_dir/snes.aud snes.wav

clean:
	rm -rf obj_dir

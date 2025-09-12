
This directory contains the Verilator simulation environment for 486Tang, allowing you to run and test the 486 core on your PC before deploying to hardware.

To run a simulation, first prepare a sd card image file `sdcard_debug.img` using `../tools/mksdcard.py`. Then  `make sim`. If you see a yellow line of text a few seconds into the simulation: `$Revision: 13073 $ $Date: 2017-02-16 22:43:52 +0100 (Do, 16. Feb 2017) $`, then your BIOS is running. At simulation time of around 4.5 million, you should start to see BIOS POST messages on the screen and in the terminal.

If any goes wrong, use `make boot` to trace the boot process to `waveform.fst` and debug with gtkwave.

The simulator also supports recording various kinds of data. For example, `obj_dir/Vsystem --sound --record sdcard_debug.img` will record Sound Blast DSP sound into `dsp.wav`.





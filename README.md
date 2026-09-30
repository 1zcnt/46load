# 46load

A 512-byte i386 MBR bootloader that finds a kernel on an ext2 partition, loads
it as an ELF file and jumps to it in 32-bit protected mode.

- relocates itself, switches to 80x50 text mode, reads the disk with BIOS
  `int 13h` extended reads
- ext2: reads the superblock and the root directory inode, looks up the file
  `k46` in the root directory
- ELF: copies every `PT_LOAD` segment to its virtual address, then jumps to
  `e_entry` with flat 4 GiB code/data segments

Limitations, to fit in one sector: only the first 12 (direct) blocks of the
kernel are loaded (12-96 KiB depending on block size), only the first block
group's inode table is read, and the A20 line is not enabled.

## Build

The Makefile is for BSD make (tested on FreeBSD). It expects an ext2 image
at `../ext2.img` with the kernel stored as `/k46`, and writes the image after
the boot sector:

```sh
make          # bmake on Linux
make run      # qemu-system-i386 -hda mbr.bin
```

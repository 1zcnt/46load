		.text
		.code16
		.global start

#define STARTADDR 		0x7c00
#define MBR_SECTOR_SIZE 0x200
#define MBR_MAGIC_POS 	MBR_SECTOR_SIZE - 2
#define MBR_MAGIC_ALIAS MBR_MAGIC_POS + 0x10

#define SUPERBLOCK_FIRST_INODE		84
#define SUPERBLOCK_INODE_SIZE		88
#define SUPERBLOCK_LOG_BLOCK_SIZE	24
#define SUPERBLOCK_INODES_PER_GROUP	40

#define BDT_OFFSET					1024
#define BDT_INODE_TABLE				8

#define INODE_BLOCK					40
#define INODE_BLOCKS				28

#define DIRENT_INODE				0
#define DIRENT_SIZE					4
#define DIRENT_NAME					8

#define ELF_ENTRY_VADDR					0x18
#define ELF_PROG_HEADER_TABLE_ENTRIES	0x2C

#define ELF_PROG_HEADER_SIZE			0x28
#define ELF_PROG_HEADER_TABLE			0x34

#define ELF_PROG_SECTION_SEGTYPE		0x00
#define ELF_PROG_SECTION_FILEOFFSET		0x04
#define ELF_PROG_SECTION_VADDR			0x08
#define ELF_PROG_SECTION_FSIZE			0x10

#define GDT_ENTRY(base, limit, access, flags) \
	(limit			& 0xFFFF)	<< 0	| \
	(base			& 0xFFFFFF)	<< 16	| \
	(access			& 0xFF)   	<< 40	| \
	((limit>>16) 	& 0xF)		<< 48	| \
	(flags			& 0xF)		<< 52	| \
	((base>>24)		& 0xFF)		<< 56

#define GDT_ENTRY_CS(base, limit) \
	GDT_ENTRY(base, limit, 0x9A, 0xC)

#define GDT_ENTRY_DS(base, limit) \
	GDT_ENTRY(base, limit, 0x92, 0xC)

start:
	# init segments and stack pointer
	movw $0x07a0, 	%ax
	movw %ax, 		%ds
	movw %ax, 		%es
	xor	 %ax, 		%ax
	movw %ax, 		%ss
	movw $0x7a00,   %sp

# 80x50 textmode
vga_mode:
	movw $3, %ax
	int $0x10
	movw $0x1112, %ax
	xor %bl, %bl
	int $0x10

# relocate rest of code
relocate:
	movw 	$check_a20, 		%di	# to	0x07a0:check_a20
	movw 	$0x200+check_a20, 	%si	# from 	0x07c0:check_a20
	movw 	$0x200-check_a20, 	%cx	# relocate MBR_SECTOR_SIZE-check_a20 bytes
	rep 	movsb					# copy
	jmp 	$0x7a0,$check_a20		# jump and fix %cs

check_a20:
	push	%ds
	push	%es
	xor		%ax, %ax
	movw	%ax, %ds
	neg		%ax
	movw	%ax, %es

	movw %ds:STARTADDR+MBR_MAGIC_POS,   %ax
	cmpw %es:STARTADDR+MBR_MAGIC_ALIAS, %ax
	jz err

	pop %es
	pop %ds

	movb %dl, dri

load_file:
	movw $1, 	%ax
	movw $2, 	%bx
	call read_blocks # read superblock

	movw 0x200 + SUPERBLOCK_INODE_SIZE, 		%dx
	movw 0x200 + SUPERBLOCK_LOG_BLOCK_SIZE, 	%cx
	movw 0x200 + SUPERBLOCK_INODES_PER_GROUP, 	%ax

	movw %dx,	%bx
	addb %cl, 	log_blksz	# update block size as in FS

	addb	$10, 	%cl 	# log2(blksize) += 10 (minimal blksize in ext2)
	shrb	$1, 	%cl  	# log2(blksize) /= 2, log2(blksize) % 2 -> CF
	jnc		carry_skip		#	if (CF == 1)
	shrw 	$1,		%ax		#		then s_inodes_per_group /= 2
carry_skip:
	shrw	%cl,	%ax		# s_inodes_per_group /= 2^(log2(blksize))
	shrw	%cl,	%dx		# s_inode_size /= 2^(log2(blksize))

	imul 	%dx,	%ax		# s_inodes_per_group *= s_inode_size
	movw	%bx,	%dx

	movw %ax, %bx
	movw 0x200 + BDT_OFFSET + BDT_INODE_TABLE, %ax
	movw $0x2000, read_params_location # read inode table to safe place(0x7c00 + max block size)
	call read_blocks

load_rootdir_block:
	movw $0, 	read_params_location	# reset read params location back to 07c0:0000

	movw $0x2, 	%bx 					# read second inode (root directory)
	call load_inode 					# now bx points to dirents block

	movw (%bx), %ax
	movw $1, 	%bx
	call read_blocks 					# load dirents block


	xor %bx, %bx
find_name_loop:
	cmpw $0, DIRENT_SIZE+0x200(%bx)		# dirent->d_size == 0 ?
	jz err								# if so - couldn't find kernel; fault

	leaw DIRENT_NAME+0x200(%bx), %di	# store dirent->d_name address in %di

	movw DIRENT_INODE+0x200(%bx), %ax	# store dirent->d_inode in %ax
	addw DIRENT_SIZE+0x200(%bx), %bx	# move on to next dirent

	call fnamecmp						# compare filename
	jc find_name_loop					# if didn't match, try next dirent

	push %ax							# save dirent->d_inode

	pop %bx
	call load_inode						# load dirent->d_inode info

	# TODO: load block by block, including indirect blocks;
	# 		this code may cause some problems in near future.
	# 			ax -> blocks
	# 			bx -> ptr to block
	movw $0x2000, read_params_location 	# read file to safe place(0x7c00 + max block size)
	movw (%bx), %dx
	movw %ax, %bx
	movw %dx, %ax
	call read_blocks

enter_pm:
	cli
	lgdt (gdtr)
	movl %cr0, 	%eax
	orb  $1, 	%al
	movl %eax,	%cr0

	jmp $0x08, $pm_entry + 0x7a00

fnamecmp:
	cld
	push %cx
	push %dx
	movw $_fname_e-fname, %cx
	movw $0, %dx

	movw $fname, %si
	rep cmpsb

	jc fnamecmp_ret
	subw %cx, %dx # rep cmpsb stopped before expected -> strings dont match


fnamecmp_ret:
	pop %dx
	pop %cx
	ret


# bx <- inode
# ax -> blocks
# bx -> ptr to block
load_inode:
	dec %bx
	imul %dx, %bx
	addw $0x2200+INODE_BLOCKS, %bx
	movw (%bx), %ax
	addw $INODE_BLOCK-INODE_BLOCKS, %bx
	ret
# ax - block id
# bx - count
read_blocks:
	call blk_to_sector
	movw %bx, read_params_sectors

	push 	%dx
	movw 	$read_params,	%si
	movb 	$0x42,			%ah
	movb 	dri,			%dl
	int		$0x13
	jc 		err

	pop %dx
	ret

blk_to_sector:
	push %bx
	movl part_start_lba, %ebx	# read partition offset
	movl %ebx, read_params_lba_start

	movb log_blksz, %cl
	shlw %cl, %ax						# fs blocks -> disk sectors
	addl %eax, read_params_lba_start	# apply partition offset to fs block offset

	pop %bx
	shlw %cl, %bx				# fs blocks -> disk sectors
	ret


err: jmp .

.code32
pm_entry:
	movl $0x10, %eax
	movl %eax, %ds
	movl %eax, %es
	movl %eax, %ss
	movl $0x7a00, %esp

load_elf:
	movl $0x9c00, %ebx
	xor %ecx, %ecx
	movw ELF_PROG_HEADER_TABLE_ENTRIES(%ebx), %cx
	addl $ELF_PROG_HEADER_TABLE, %ebx

load_elf_loop:
	dec %ecx
	movl %ecx, %eax
	pushl %ecx

	imul $ELF_PROG_HEADER_SIZE, %eax
	movl ELF_PROG_SECTION_SEGTYPE(%ebx, %eax), %edx
	cmpl $1, %edx
	jnz load_elf_loop	# skip this segment if SEGTYPE isn't PT_LOAD

	movl ELF_PROG_SECTION_VADDR(%ebx, %eax), %edi		# section VADDR
	movl ELF_PROG_SECTION_FILEOFFSET(%ebx, %eax), %esi  # data offset in ELF file
	addl $0x9c00, %esi									# ELF offset in memory

	movl ELF_PROG_SECTION_FSIZE(%ebx, %eax), %ecx		# section size in bytes
	rep movsb											# load section to its VADDR

	popl %ecx
	cmpl $0, %ecx
	jnz load_elf_loop

jmpkernel:
	movl ELF_ENTRY_VADDR+0x9c00, %ebx
	jmp  *%ebx

data_start:
dri: .byte 0
gdtr:
	.short gdt_end-gdtr-1
	.long  gdtr+0x7a00
	.word 0
	.quad GDT_ENTRY_CS(0x000000, 0xFFFFFFFF)
	.quad GDT_ENTRY_DS(0x000000, 0xFFFFFFFF)
gdt_end:

fname:
.ascii "k46"
_fname_e:

# s_log_block_size + 1
log_blksz: .byte 1

read_params:
	.byte 0x10
	.byte 0x00
read_params_sectors:
	.word 0x0001
read_params_location:
	.word 0x0000
	.word 0x07c0
read_params_lba_start:
	.long 180
	.long 0
data_end:

.org 0x1b8
	.ascii "46LD"
	.word 0xFAFA
	#part1
	.byte 0b01000000

	.byte 1
	.byte 0
	.byte 0

	.byte 0xab

	# 2MB partition
	.byte 4
	.byte 16
	.byte 63

	part_start_lba:
	.long 0
	.long 512
.org MBR_MAGIC_POS
	.word 0xaa55

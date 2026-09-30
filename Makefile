S=		${.CURDIR}/..

PROG=		mbr
SRCS=		${PROG}.S

MK_MAN=		no

afterbuild:
	${OBJCOPY} -O binary --only-section=.text ${PROG} ${PROG}.bin
	dd if=../ext2.img of=mbr.bin bs=512 skip=1 seek=1

run: ${PROG} afterbuild
	qemu-system-i386 -hda ${PROG}.bin


.include <bsd.prog.mk>
CFLAGS=
ACFLAGS+= -g -m32
LDFLAGS=  -g -fno-pic -nostdlib -e start -Xlinker "-melf_i386" -Xlinker "--Ttext=0x0"

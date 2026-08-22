/* Remplit /dev/fb0 en RGB888/ARGB (bpp 32) — usage: fbcolor R G B */
#include <fcntl.h>
#include <linux/fb.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	int fd, r = 0, g = 0, b = 0;
	struct fb_var_screeninfo vinfo;
	struct fb_fix_screeninfo finfo;
	size_t size;
	uint8_t *fb;
	uint32_t pixel;
	size_t i;

	if (argc >= 4) {
		r = atoi(argv[1]);
		g = atoi(argv[2]);
		b = atoi(argv[3]);
	}

	fd = open("/dev/fb0", O_RDWR);
	if (fd < 0) {
		perror("fb0");
		return 1;
	}
	if (ioctl(fd, FBIOGET_FSCREENINFO, &finfo) ||
	    ioctl(fd, FBIOGET_VSCREENINFO, &vinfo)) {
		perror("ioctl");
		close(fd);
		return 1;
	}
	size = finfo.smem_len;
	fb = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (fb == MAP_FAILED) {
		perror("mmap");
		close(fd);
		return 1;
	}

	/* ARGB8888 / XRGB little-endian */
	pixel = ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)b;
	if (vinfo.bits_per_pixel == 32) {
		uint32_t *p = (uint32_t *)fb;
		size_t n = size / 4;
		for (i = 0; i < n; i++)
			p[i] = pixel;
	} else if (vinfo.bits_per_pixel == 16) {
		uint16_t *p = (uint16_t *)fb;
		uint16_t pix = (uint16_t)(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
		size_t n = size / 2;
		for (i = 0; i < n; i++)
			p[i] = pix;
	}

	munmap(fb, size);
	close(fd);
	fprintf(stderr, "fbcolor %d %d %d %dx%d bpp=%d\n",
		r, g, b, vinfo.xres, vinfo.yres, vinfo.bits_per_pixel);
	return 0;
}

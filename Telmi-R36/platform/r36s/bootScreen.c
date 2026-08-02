#include <fcntl.h>
#include <linux/fb.h>
#include <png.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include "utils/flags.h"

/* Splash Telmi sans SDL — PNG via libpng + blit framebuffer. */

#define BG_RGB565 0x4015 /* violet Telmi */
#define BG_ARGB32 0xFF25103A

static void step(const char *msg)
{
	int fd = open("/boot/bootScreen.steps", O_WRONLY | O_CREAT | O_APPEND, 0644);
	if (fd < 0)
		fd = open("/tmp/bootScreen.steps", O_WRONLY | O_CREAT | O_APPEND, 0644);
	if (fd >= 0) {
		write(fd, msg, strlen(msg));
		write(fd, "\n", 1);
		fsync(fd);
		close(fd);
	}
	write(STDERR_FILENO, msg, strlen(msg));
	write(STDERR_FILENO, "\n", 1);
}

static void unblank(void)
{
	int fd = open("/sys/class/graphics/fb0/blank", O_WRONLY);
	if (fd >= 0) {
		write(fd, "0", 1);
		close(fd);
	}
}

static uint16_t rgb_to_565(uint8_t r, uint8_t g, uint8_t b)
{
	return (uint16_t)(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3));
}

/* Charge PNG → buffer RGB packed (w*h*3). */
static uint8_t *load_png_rgb(const char *path, int *out_w, int *out_h)
{
	FILE *fp;
	png_structp png = NULL;
	png_infop info = NULL;
	png_bytep *rows = NULL;
	uint8_t *rgb = NULL;
	uint8_t *raw = NULL;
	int w, h, y;
	size_t rowbytes;

	fp = fopen(path, "rb");
	if (!fp)
		return NULL;

	png = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
	if (!png) {
		fclose(fp);
		return NULL;
	}
	info = png_create_info_struct(png);
	if (!info) {
		png_destroy_read_struct(&png, NULL, NULL);
		fclose(fp);
		return NULL;
	}
	if (setjmp(png_jmpbuf(png))) {
		png_destroy_read_struct(&png, &info, NULL);
		fclose(fp);
		free(rows);
		free(raw);
		free(rgb);
		return NULL;
	}

	png_init_io(png, fp);
	png_read_info(png, info);
	w = (int)png_get_image_width(png, info);
	h = (int)png_get_image_height(png, info);

	if (png_get_bit_depth(png, info) == 16)
		png_set_strip_16(png);
	if (png_get_color_type(png, info) == PNG_COLOR_TYPE_PALETTE)
		png_set_palette_to_rgb(png);
	if (png_get_color_type(png, info) == PNG_COLOR_TYPE_GRAY &&
	    png_get_bit_depth(png, info) < 8)
		png_set_expand_gray_1_2_4_to_8(png);
	if (png_get_valid(png, info, PNG_INFO_tRNS))
		png_set_tRNS_to_alpha(png);
	if (png_get_color_type(png, info) == PNG_COLOR_TYPE_GRAY ||
	    png_get_color_type(png, info) == PNG_COLOR_TYPE_GRAY_ALPHA)
		png_set_gray_to_rgb(png);
	if (png_get_color_type(png, info) == PNG_COLOR_TYPE_RGB_ALPHA ||
	    png_get_color_type(png, info) == PNG_COLOR_TYPE_GRAY_ALPHA ||
	    png_get_valid(png, info, PNG_INFO_tRNS))
		png_set_strip_alpha(png);

	png_read_update_info(png, info);
	rowbytes = png_get_rowbytes(png, info);

	rows = (png_bytep *)calloc((size_t)h, sizeof(png_bytep));
	raw = (uint8_t *)malloc(rowbytes * (size_t)h);
	if (!rows || !raw)
		longjmp(png_jmpbuf(png), 1);

	for (y = 0; y < h; y++)
		rows[y] = raw + (size_t)y * rowbytes;

	png_read_image(png, rows);
	png_read_end(png, NULL);

	rgb = (uint8_t *)malloc((size_t)w * (size_t)h * 3);
	if (!rgb)
		longjmp(png_jmpbuf(png), 1);

	/* Normalise vers RGB 3 octets / pixel (rowbytes peut etre aligne). */
	if (rowbytes == (size_t)w * 3) {
		memcpy(rgb, raw, (size_t)w * (size_t)h * 3);
	} else {
		for (y = 0; y < h; y++)
			memcpy(rgb + (size_t)y * (size_t)w * 3, rows[y], (size_t)w * 3);
	}

	png_destroy_read_struct(&png, &info, NULL);
	fclose(fp);
	free(rows);
	free(raw);

	*out_w = w;
	*out_h = h;
	return rgb;
}

static const char *find_splash(int is_end)
{
	static const char *boot_paths[] = {
		"/opt/telmi/res/bootScreen.png",
		"/telmi/.tmp_update/res/bootScreen.png",
		"/mnt/SDCARD/.tmp_update/res/bootScreen.png",
		NULL,
	};
	static const char *end_paths[] = {
		"/opt/telmi/res/Screen_Off.png",
		"/telmi/.tmp_update/res/Screen_Off.png",
		"/mnt/SDCARD/.tmp_update/res/Screen_Off.png",
		NULL,
	};
	const char **p = is_end ? end_paths : boot_paths;
	int i;

	for (i = 0; p[i]; i++) {
		if (access(p[i], R_OK) == 0)
			return p[i];
	}
	return NULL;
}

static void fill_solid(char *fbp, const struct fb_fix_screeninfo *finfo,
		       const struct fb_var_screeninfo *vinfo, int black)
{
	long i, n;

	if (vinfo->bits_per_pixel == 16) {
		uint16_t *p = (uint16_t *)fbp;
		uint16_t c = black ? 0 : BG_RGB565;
		n = finfo->smem_len / 2;
		for (i = 0; i < n; i++)
			p[i] = c;
	} else if (vinfo->bits_per_pixel == 32) {
		uint32_t *p = (uint32_t *)fbp;
		uint32_t c = black ? 0xFF000000u : BG_ARGB32;
		n = finfo->smem_len / 4;
		for (i = 0; i < n; i++)
			p[i] = c;
	} else {
		memset(fbp, black ? 0 : 0x20, finfo->smem_len);
	}
}

static void blit_rgb(char *fbp, const struct fb_fix_screeninfo *finfo,
		     const struct fb_var_screeninfo *vinfo,
		     const uint8_t *rgb, int iw, int ih)
{
	int fw = (int)vinfo->xres;
	int fh = (int)vinfo->yres;
	int ox = (fw - iw) / 2;
	int oy = (fh - ih) / 2;
	int x, y, sx, sy;
	long line_bytes = (long)finfo->line_length;

	fill_solid(fbp, finfo, vinfo, 0);

	for (y = 0; y < ih; y++) {
		sy = oy + y;
		if (sy < 0 || sy >= fh)
			continue;
		for (x = 0; x < iw; x++) {
			sx = ox + x;
			if (sx < 0 || sx >= fw)
				continue;
			{
				const uint8_t *px = rgb + ((size_t)y * (size_t)iw + (size_t)x) * 3;
				uint8_t r = px[0], g = px[1], b = px[2];

				if (vinfo->bits_per_pixel == 16) {
					uint16_t *dst = (uint16_t *)(fbp + sy * line_bytes + sx * 2);
					*dst = rgb_to_565(r, g, b);
				} else if (vinfo->bits_per_pixel == 32) {
					uint32_t *dst = (uint32_t *)(fbp + sy * line_bytes + sx * 4);
					*dst = 0xFF000000u | ((uint32_t)r << 16) |
					       ((uint32_t)g << 8) | b;
				}
			}
		}
	}
}

static int show_splash(int is_end)
{
	struct fb_var_screeninfo vinfo;
	struct fb_fix_screeninfo finfo;
	int fd;
	char *fbp;
	const char *path;
	uint8_t *rgb = NULL;
	int iw = 0, ih = 0;

	fd = open("/dev/fb0", O_RDWR);
	if (fd < 0) {
		step("open fb0 FAIL");
		return 1;
	}
	if (ioctl(fd, FBIOGET_FSCREENINFO, &finfo) ||
	    ioctl(fd, FBIOGET_VSCREENINFO, &vinfo)) {
		step("ioctl fb0 FAIL");
		close(fd);
		return 1;
	}

	{
		char buf[96];
		snprintf(buf, sizeof(buf), "fb %dx%d bpp=%d",
			 vinfo.xres, vinfo.yres, vinfo.bits_per_pixel);
		step(buf);
	}

	fbp = mmap(0, finfo.smem_len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (fbp == MAP_FAILED) {
		step("mmap fb0 FAIL");
		close(fd);
		return 1;
	}

	path = find_splash(is_end);
	if (path) {
		char buf[160];
		snprintf(buf, sizeof(buf), "png %s", path);
		step(buf);
		rgb = load_png_rgb(path, &iw, &ih);
	}

	if (rgb && iw > 0 && ih > 0) {
		blit_rgb(fbp, &finfo, &vinfo, rgb, iw, ih);
		step("fb logo OK");
		free(rgb);
	} else if (is_end) {
		fill_solid(fbp, &finfo, &vinfo, 1);
		step("fb black OK");
	} else {
		fill_solid(fbp, &finfo, &vinfo, 0);
		step("fb solid OK (no png)");
	}

	munmap(fbp, finfo.smem_len);
	close(fd);
	return 0;
}

int main(int argc, char *argv[])
{
	int is_end = (argc > 1 && strcmp(argv[1], "End") == 0);

	unlink("/boot/bootScreen.steps");
	step("bootScreen fb start");
	unblank();
	show_splash(is_end);

	if (argc > 1 && strcmp(argv[1], "Boot") != 0)
		temp_flag_set(".offOrder", false);

	step("bootScreen OK");
	return EXIT_SUCCESS;
}

#include <fcntl.h>
#include <linux/fb.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

/* Probe ecran R36S : framebuffer direct + optionnellement SDL.
 * Ecrit chaque etape dans /boot/sdl-steps.log (pas de buffering). */

static void step(const char *msg)
{
	int fd = open("/boot/sdl-steps.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
	if (fd < 0)
		fd = open("/tmp/sdl-steps.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
	if (fd >= 0) {
		write(fd, msg, strlen(msg));
		write(fd, "\n", 1);
		fsync(fd);
		close(fd);
	}
	write(STDERR_FILENO, msg, strlen(msg));
	write(STDERR_FILENO, "\n", 1);
}

static int fill_fb(uint16_t color)
{
	struct fb_var_screeninfo vinfo;
	struct fb_fix_screeninfo finfo;
	int fd;
	char *fbp;
	long ssize;
	long i;

	fd = open("/dev/fb0", O_RDWR);
	if (fd < 0) {
		step("fb0: open FAIL");
		return 1;
	}
	step("fb0: open OK");

	if (ioctl(fd, FBIOGET_FSCREENINFO, &finfo) ||
	    ioctl(fd, FBIOGET_VSCREENINFO, &vinfo)) {
		step("fb0: ioctl FAIL");
		close(fd);
		return 1;
	}

	{
		char buf[128];
		snprintf(buf, sizeof(buf), "fb0: %dx%d bpp=%d",
			vinfo.xres, vinfo.yres, vinfo.bits_per_pixel);
		step(buf);
	}

	ssize = finfo.smem_len;
	fbp = mmap(0, ssize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (fbp == MAP_FAILED) {
		step("fb0: mmap FAIL");
		close(fd);
		return 1;
	}
	step("fb0: mmap OK — remplissage");

	if (vinfo.bits_per_pixel == 16) {
		uint16_t *p = (uint16_t *)fbp;
		long n = ssize / 2;
		for (i = 0; i < n; i++)
			p[i] = color;
	} else if (vinfo.bits_per_pixel == 32) {
		uint32_t *p = (uint32_t *)fbp;
		long n = ssize / 4;
		uint32_t c32 = 0xFF003060;
		for (i = 0; i < n; i++)
			p[i] = c32;
	} else {
		memset(fbp, 0x30, ssize);
	}

	munmap(fbp, ssize);
	close(fd);
	step("fb0: done");
	return 0;
}

#ifdef WITH_SDL
#include <SDL2/SDL.h>

static int try_sdl(void)
{
	SDL_Window *w;
	SDL_Renderer *r;

	step("SDL: avant Init");
	if (SDL_Init(SDL_INIT_VIDEO) != 0) {
		step(SDL_GetError());
		step("SDL: Init FAIL");
		return 1;
	}
	step("SDL: Init OK");

	w = SDL_CreateWindow("probe", SDL_WINDOWPOS_UNDEFINED,
		SDL_WINDOWPOS_UNDEFINED, 640, 480, SDL_WINDOW_FULLSCREEN_DESKTOP);
	if (!w) {
		step(SDL_GetError());
		step("SDL: CreateWindow FAIL");
		SDL_Quit();
		return 1;
	}
	step("SDL: CreateWindow OK");

	r = SDL_CreateRenderer(w, -1, SDL_RENDERER_SOFTWARE);
	if (!r)
		r = SDL_CreateRenderer(w, -1, SDL_RENDERER_ACCELERATED);
	if (!r) {
		step(SDL_GetError());
		step("SDL: CreateRenderer FAIL");
		SDL_DestroyWindow(w);
		SDL_Quit();
		return 1;
	}
	step("SDL: CreateRenderer OK");

	SDL_SetRenderDrawColor(r, 0, 48, 96, 255);
	SDL_RenderClear(r);
	SDL_RenderPresent(r);
	step("SDL: Present OK");
	sleep(2);

	SDL_DestroyRenderer(r);
	SDL_DestroyWindow(w);
	SDL_Quit();
	step("SDL: done");
	return 0;
}
#endif

int main(int argc, char **argv)
{
	(void)argc;
	(void)argv;
	unlink("/boot/sdl-steps.log");
	unlink("/tmp/sdl-steps.log");
	step("probe: start");

	if (fill_fb(0x001F) != 0) /* bleu RGB565 */
		step("probe: fb FAIL");
	else
		step("probe: fb OK");

#ifdef WITH_SDL
	step("probe: try SDL");
	if (try_sdl() != 0)
		step("probe: SDL FAIL");
	else
		step("probe: SDL OK");
#endif
	step("probe: end");
	return 0;
}

/* desktop wallpaper: load an image with imlib2 and render it into a
   pixmap the size of the screen */

#include <X11/Xlib.h>
#include <Imlib2.h>
#include <stdio.h>
#include <stdlib.h>

/* returns the pixmap, or 0 when the image cannot be read */
unsigned long mx_wallpaper(Display *dpy, Window root, Visual *visual,
                           Colormap colormap, int depth, const char *path,
                           int sw, int sh)
{
	char full[4096];
	const char *home = getenv("HOME");
	Imlib_Image img;
	Pixmap pm;
	int w, h, cw, ch;

	if (path[0] == '~' && path[1] == '/' && home) {
		snprintf(full, sizeof full, "%s%s", home, path + 1);
		path = full;
	}
	img = imlib_load_image_immediately(path);
	if (!img)
		return 0;
	imlib_context_set_image(img);
	w = imlib_image_get_width();
	h = imlib_image_get_height();

	pm = XCreatePixmap(dpy, root, sw, sh, depth);
	imlib_context_set_display(dpy);
	imlib_context_set_visual(visual);
	imlib_context_set_colormap(colormap);
	imlib_context_set_drawable(pm);
	imlib_context_set_anti_alias(1);

	/* cover the screen, cropping the overflow evenly from both sides */
	if ((long)w * sh > (long)h * sw) {
		ch = h;
		cw = (int)((long)h * sw / sh);
	} else {
		cw = w;
		ch = (int)((long)w * sh / sw);
	}
	imlib_render_image_part_on_drawable_at_size((w - cw) / 2, (h - ch) / 2,
	                                            cw, ch, 0, 0, sw, sh);
	imlib_free_image();
	return pm;
}

import sys
path = sys.argv[1]
s = open(path).read()

def sub(old, new):
    global s
    assert s.count(old) == 1, old[:70]
    s = s.replace(old, new)

# helper, defined right before the request handler
sub("""static void
shell_backend_request_window_move(struct weston_surface *surface, int x, int y, int width, int height)
{""", """/* A client move/resize that leaves the snapped rect means the window is no
 * longer snapped (same state change as an interactive unsnap). Otherwise the
 * commit handler would keep putting it back at the snapped position. */
static void
shell_surface_client_move_unsnap(struct shell_surface *shsurf, int x, int y,
				 int width, int height)
{
	struct weston_surface *surface =
		weston_desktop_surface_get_surface(shsurf->desktop_surface);
	struct weston_surface_rail_state *rail_state =
		(struct weston_surface_rail_state *)surface->backend_state;

	if (!shsurf->snapped.is_snapped ||
	    (x == shsurf->snapped.x && y == shsurf->snapped.y &&
	     width == shsurf->snapped.width && height == shsurf->snapped.height))
		return;

	shsurf->snapped.is_snapped = false;
	shsurf->saved_showstate_valid = false;
	if (rail_state) {
		rail_state->isWindowSnapped = false;
		rail_state->showState_requested = RDP_WINDOW_SHOW;
	}
}

static void
shell_backend_request_window_move(struct weston_surface *surface, int x, int y, int width, int height)
{""")

# resize path: sizes are window-geometry here, like snapped.width/height
sub("""			height = max_size.height;

		if (width != geometry.width || height != geometry.height) {""",
"""			height = max_size.height;

		shell_surface_client_move_unsnap(shsurf, x, y, width, height);

		if (width != geometry.width || height != geometry.height) {""")

# plain move path: only the position can differ
sub("""	/* A plain move supersedes any move still waiting for a resize. */""",
"""	shell_surface_client_move_unsnap(shsurf, x, y,
					 shsurf->snapped.width, shsurf->snapped.height);

	/* A plain move supersedes any move still waiting for a resize. */""")
open(path, "w").write(s)

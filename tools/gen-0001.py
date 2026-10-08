import sys
path = sys.argv[1]
s = open(path).read()

def sub(old, new):
    global s
    assert s.count(old) == 1, old[:70]
    s = s.replace(old, new)

# 1. per-surface state for a deferred client move
sub("""	int unresponsive, grabbed;
	uint32_t resize_edges;
""", """	int unresponsive, grabbed;
	uint32_t resize_edges;

	/* A Client Window Move that also resized the window: the new position
	 * is applied when the app commits its resized buffer, so position and
	 * size reach the RDP client in one window update. Moving the view
	 * first would make the backend send the new position with the old
	 * size, and the client would briefly snap the window back to it. */
	struct {
		bool pending;
		int32_t x, y;
		struct wl_event_source *timeout;
	} client_move;
""")

# 2. free the timer with the surface
sub("""	if (shsurf->metadata_listener.notify) {
		wl_list_remove(&shsurf->metadata_listener.link);
		shsurf->metadata_listener.notify = NULL;
	}

	free(shsurf);
""", """	if (shsurf->metadata_listener.notify) {
		wl_list_remove(&shsurf->metadata_listener.link);
		shsurf->metadata_listener.notify = NULL;
	}

	if (shsurf->client_move.timeout)
		wl_event_source_remove(shsurf->client_move.timeout);

	free(shsurf);
""")

# 3. apply it once the resized buffer arrives
sub("""	if (sx == 0 && sy == 0 &&
	    shsurf->last_width == surface->width &&""", """	if (shsurf->client_move.pending &&
	    (shsurf->last_width != surface->width ||
	     shsurf->last_height != surface->height))
		shell_surface_apply_client_move(shsurf);

	if (sx == 0 && sy == 0 &&
	    shsurf->last_width == surface->width &&""")

# helpers, placed just before desktop_surface_committed()
sub("""static void
desktop_surface_committed(struct weston_desktop_surface *desktop_surface,""", """static void
shell_surface_apply_client_move(struct shell_surface *shsurf)
{
	if (!shsurf->client_move.pending)
		return;
	shsurf->client_move.pending = false;
	if (shsurf->client_move.timeout)
		wl_event_source_timer_update(shsurf->client_move.timeout, 0);
	weston_view_set_position(shsurf->view, shsurf->client_move.x,
				 shsurf->client_move.y);
	weston_view_schedule_repaint(shsurf->view);
}

static int
shell_surface_client_move_timeout(void *data)
{
	/* The app did not resize in time (fixed size, unresponsive, ...):
	 * move it anyway. */
	shell_surface_apply_client_move(data);
	return 0;
}

static void
desktop_surface_committed(struct weston_desktop_surface *desktop_surface,""")

# 4a. Client Window Move for a surface without a shell surface (a popup,
#     menu or tooltip) used to dereference NULL. msrdc never sends one, but
#     anything that moves a popup's RAIL window (e.g. a window manager plus a
#     forwarder) crashed Weston.
sub("""	view = get_default_view(surface);
	if (!view)
		return;

	if (shsurf && shsurf->shell->is_localmove_pending) {""",
"""	view = get_default_view(surface);
	/* Only shell surfaces (toplevels) can be moved this way; a request for
	 * a popup would otherwise dereference a NULL shsurf below. */
	if (!view || !shsurf)
		return;

	if (shsurf->shell->is_localmove_pending) {""")

# 4. the request handler itself
sub("""	if (surface->width != width || surface->height != height) {
		//TODO: support window resize (width x height)
		shell_rdp_debug(shsurf->shell, "%s: surface:%p is resized (%dx%d) -> (%d,%d)\\n",
			__func__, surface, surface->width, surface->height, width, height);
	}

	weston_view_set_position(view, x, y);
""", """	if ((surface->width != width || surface->height != height) &&
	    !shsurf->state.maximized && !shsurf->state.fullscreen) {
		struct weston_desktop_surface *desktop_surface =
			weston_surface_get_desktop_surface(surface);
		struct weston_geometry geometry =
			weston_desktop_surface_get_geometry(desktop_surface);
		struct weston_size max_size = weston_desktop_surface_get_max_size(desktop_surface);
		struct weston_size min_size = weston_desktop_surface_get_min_size(desktop_surface);

		shell_rdp_debug(shsurf->shell, "%s: surface:%p is resized (%dx%d) -> (%d,%d)\\n",
			__func__, surface, surface->width, surface->height, width, height);

		/* Same conversion as request_window_snap: incoming size includes the
		 * shadow/CSD margin, set_size() wants window-geometry coordinates. */
		width -= (surface->width - geometry.width);
		height -= (surface->height - geometry.height);

		min_size.width = MAX(1, min_size.width);
		min_size.height = MAX(1, min_size.height);
		if (width < min_size.width)
			width = min_size.width;
		else if (max_size.width > 0 && width > max_size.width)
			width = max_size.width;
		if (height < min_size.height)
			height = min_size.height;
		else if (max_size.height > 0 && height > max_size.height)
			height = max_size.height;

		if (width != geometry.width || height != geometry.height) {
			if (!shsurf->client_move.timeout) {
				struct wl_event_loop *loop =
					wl_display_get_event_loop(shsurf->shell->compositor->wl_display);
				shsurf->client_move.timeout =
					wl_event_loop_add_timer(loop, shell_surface_client_move_timeout, shsurf);
			}
			if (shsurf->client_move.timeout) {
				weston_desktop_surface_set_size(desktop_surface, width, height);
				shsurf->client_move.pending = true;
				shsurf->client_move.x = x;
				shsurf->client_move.y = y;
				wl_event_source_timer_update(shsurf->client_move.timeout, 250);
				shell_rdp_debug(shsurf->shell, "%s: surface:%p move to (%d,%d) deferred until resized\\n",
					__func__, surface, x, y);
				return;
			}
			weston_desktop_surface_set_size(desktop_surface, width, height);
		}
	}

	/* A plain move supersedes any move still waiting for a resize. */
	shsurf->client_move.pending = false;
	if (shsurf->client_move.timeout)
		wl_event_source_timer_update(shsurf->client_move.timeout, 0);

	weston_view_set_position(view, x, y);
""")
open(path, "w").write(s)

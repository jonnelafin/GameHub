/*
This file is part of GameHub.
Copyright (C) 2018-2019 Anatoliy Kashkin

GameHub is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

GameHub is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with GameHub.  If not, see <https://www.gnu.org/licenses/>.
*/

using Gtk;
using Gdk;
using GLib;
using Gee;
using Granite;
using GameHub.Data;
using GameHub.Data.Adapters;
using GameHub.Data.DB;
using GameHub.Utils;
using GameHub.UI.Widgets;
using GameHub.UI.Windows;

namespace GameHub.UI.Views.GamesView
{
	public class GamesView: BaseView
	{
		public static GamesView instance;

		private ArrayList<GameSource> sources = new ArrayList<GameSource>();

		private GamesAdapter games_adapter;

		private Box messages;

		private Stack stack;

		private Granite.Widgets.AlertView empty_alert;

		private ScrolledWindow games_grid_scrolled;
		private RecyclerContainer games_grid;

		private Paned games_list_paned;
		private RecyclerContainer games_list;
		private GameDetailsView.GameDetailsView games_list_details;

		private Granite.Widgets.ModeButton view;

		private Granite.Widgets.ModeButton filter;
		private SearchEntry search;

		private Granite.Widgets.OverlayBar status_overlay;

		private Button settings;

		private MenuButton downloads;
		private Popover downloads_popover;
		private ListBox downloads_list;
		private int downloads_count = 0;

		private MenuButton filters;
		private FiltersPopover filters_popover;

		private MenuButton add_game_button;
		private AddGamePopover add_game_popover;

		private Settings.UI ui_settings;
		private Settings.SavedState saved_state;

		#if MANETTE
		private Manette.Monitor manette_monitor = new Manette.Monitor();
		private ArrayList<Manette.Device> connected_gamepads = new ArrayList<Manette.Device>();
		private bool gamepad_axes_to_keys_thread_running = false;
		private ArrayList<Widget> gamepad_mode_visible_widgets = new ArrayList<Widget>();
		private ArrayList<Widget> gamepad_mode_hidden_widgets = new ArrayList<Widget>();
		private Settings.Controller controller_settings;
		#endif

		public const string ACTION_PREFIX             = "win.";
		public const string ACTION_SOURCE_PREV        = "source.previous";
		public const string ACTION_SOURCE_NEXT        = "source.next";
		public const string ACTION_SEARCH             = "search";
		public const string ACTION_FILTERS            = "filters";
		public const string ACTION_DOWNLOADS          = "downloads";
		public const string ACTION_SELECT_RANDOM_GAME = "select-random-game";
		public const string ACTION_ADD_GAME           = "add-game";

		public const string ACCEL_SOURCE_PREV         = "F1"; // LB
		public const string ACCEL_SOURCE_NEXT         = "F2"; // RB
		public const string ACCEL_SEARCH              = "<Control>F";
		public const string ACCEL_FILTERS             = "<Alt>F";
		public const string ACCEL_DOWNLOADS           = "<Control>D";
		public const string ACCEL_SELECT_RANDOM_GAME  = "<Control>R";
		public const string ACCEL_ADD_GAME            = "<Control>N";

		private const GLib.ActionEntry[] action_entries = {
			{ ACTION_SOURCE_PREV,        window_action_handler },
			{ ACTION_SOURCE_NEXT,        window_action_handler },
			{ ACTION_SEARCH,             window_action_handler },
			{ ACTION_FILTERS,            window_action_handler },
			{ ACTION_DOWNLOADS,          window_action_handler },
			{ ACTION_SELECT_RANDOM_GAME, window_action_handler },
			{ ACTION_ADD_GAME,           window_action_handler }
		};

		construct
		{
			instance = this;

			ui_settings = Settings.UI.get_instance();
			saved_state = Settings.SavedState.get_instance();

			foreach(var src in GameSources)
			{
				if(src.enabled && src.is_authenticated()) sources.add(src);
			}

			var overlay = new Overlay();

			stack = new Stack();
			stack.transition_type = StackTransitionType.CROSSFADE;

			empty_alert = new Granite.Widgets.AlertView(_("No games"), _("Get some games or enable some game sources in settings"), "dialog-warning");

			games_adapter = new GamesAdapter();
			games_adapter.changed.connect(update_view);

			games_grid = new Widgets.RecyclerContainer(games_adapter, 0, GameCard.CARD_WIDTH_MIN, GameCard.CARD_WIDTH_MAX);
			games_grid.get_style_context().add_class("games-grid");
			games_grid.margin = 4;

			/*games_grid.activate_on_single_click = false;
			games_grid.homogeneous = true;
			games_grid.min_children_per_line = 2;
			games_grid.selection_mode = SelectionMode.BROWSE;*/
			games_grid.expand = true;

			games_grid_scrolled = new ScrolledWindow(null, null);
			games_grid_scrolled.expand = true;
			games_grid_scrolled.hscrollbar_policy = PolicyType.NEVER;
			games_grid_scrolled.add(games_grid);

			games_list_paned = new Paned(Orientation.HORIZONTAL);

			games_list = new Widgets.RecyclerContainer(games_adapter, 1);
			//games_list.selection_mode = SelectionMode.BROWSE;

			games_list_details = new GameDetailsView.GameDetailsView(null);
			games_list_details.content_margin = 16;

			var games_list_scrolled = new ScrolledWindow(null, null);
			games_list_scrolled.hscrollbar_policy = PolicyType.EXTERNAL;
			games_list_scrolled.add(games_list);
			games_list_scrolled.set_size_request(220, -1);

			games_list_paned.pack1(games_list_scrolled, false, false);
			games_list_paned.pack2(games_list_details, true, true);

			stack.add(empty_alert);
			stack.add(games_grid_scrolled);
			stack.add(games_list_paned);

			overlay.add(stack);

			messages = new Box(Orientation.VERTICAL, 0);

			attach(messages, 0, 0);
			attach(overlay, 0, 1);

			view = new Granite.Widgets.ModeButton();
			view.halign = Align.CENTER;
			view.valign = Align.CENTER;

			add_view_button("view-grid-symbolic", _("Grid view"));
			add_view_button("view-list-symbolic", _("List view"));

			view.mode_changed.connect(update_view);

			filter = new Granite.Widgets.ModeButton();
			filter.halign = Align.CENTER;
			filter.valign = Align.CENTER;

			add_filter_button("sources-all-symbolic", _("All games"));

			foreach(var src in sources)
			{
				add_filter_button(src.icon, src.name_from);
			}

			filter.set_active(sources.size > 1 ? 0 : 1);

			downloads = new MenuButton();
			downloads.valign = Align.CENTER;
			Utils.set_accel_tooltip(downloads, _("Downloads"), ACCEL_DOWNLOADS);
			downloads.image = new Image.from_icon_name("folder-download" + Settings.UI.symbolic_icon_suffix, Settings.UI.headerbar_icon_size);

			downloads_popover = new Popover(downloads);
			downloads_list = new ListBox();
			downloads_list.get_style_context().add_class("downloads-list");

			var downloads_scrolled = new ScrolledWindow(null, null);
			#if GTK_3_22
			downloads_scrolled.propagate_natural_width = true;
			downloads_scrolled.propagate_natural_height = true;
			downloads_scrolled.max_content_height = 440;
			#else
			downloads_scrolled.min_content_height = 440;
			#endif
			downloads_scrolled.add(downloads_list);
			downloads_scrolled.show_all();

			downloads_popover.add(downloads_scrolled);
			downloads_popover.position = PositionType.BOTTOM;
			downloads_popover.set_size_request(500, -1);
			downloads.popover = downloads_popover;
			downloads.sensitive = false;

			filters = new MenuButton();
			filters.valign = Align.CENTER;
			Utils.set_accel_tooltip(filters, _("Filters"), ACCEL_FILTERS);
			filters.image = new Image.from_icon_name("tag" + Settings.UI.symbolic_icon_suffix, Settings.UI.headerbar_icon_size);
			filters_popover = new FiltersPopover(filters);
			filters_popover.position = PositionType.BOTTOM;
			filters.popover = filters_popover;

			add_game_button = new MenuButton();
			add_game_button.valign = Align.CENTER;
			Utils.set_accel_tooltip(add_game_button, _("Add game"), ACCEL_ADD_GAME);
			add_game_button.image = new Image.from_icon_name("list-add" + Settings.UI.symbolic_icon_suffix, Settings.UI.headerbar_icon_size);
			add_game_popover = new AddGamePopover(add_game_button);
			add_game_popover.position = PositionType.BOTTOM;
			add_game_button.popover = add_game_popover;

			search = new SearchEntry();
			search.placeholder_text = _("Search");
			Utils.set_accel_tooltip(search, search.placeholder_text, ACCEL_SEARCH);
			search.halign = Align.CENTER;
			search.valign = Align.CENTER;

			settings = new Button();
			settings.valign = Align.CENTER;
			Utils.set_accel_tooltip(settings, _("Settings"), Application.ACCEL_SETTINGS);
			settings.image = new Image.from_icon_name("open-menu" + Settings.UI.symbolic_icon_suffix, Settings.UI.headerbar_icon_size);
			settings.action_name = Application.ACTION_PREFIX + Application.ACTION_SETTINGS;

			/*games_list.row_selected.connect(row => {
				var item = row as GameListRow;
				games_list_details.game = item != null ? item.game : null;
			});*/

			filter.mode_changed.connect(update_view);
			search.search_changed.connect(() => {
				games_adapter.filter_search_query = search.text;
				games_adapter.invalidate(true, false);
				update_view();
			});
			search.activate.connect(search_run_first_matching_game);

			ui_settings.notify["symbolic-icons"].connect(() => {
				(filters.image as Image).icon_name = "tag" + Settings.UI.symbolic_icon_suffix;
				(add_game_button.image as Image).icon_name = "list-add" + Settings.UI.symbolic_icon_suffix;
				(downloads.image as Image).icon_name = "folder-download" + Settings.UI.symbolic_icon_suffix;
				(settings.image as Image).icon_name = "open-menu" + Settings.UI.symbolic_icon_suffix;
				(filters.image as Image).icon_size = (add_game_button.image as Image).icon_size = (downloads.image as Image).icon_size = (settings.image as Image).icon_size = Settings.UI.headerbar_icon_size;
			});

			filters_popover.filters_changed.connect(() => {
				games_adapter.filter_tags = filters_popover.selected_tags;
				games_adapter.invalidate(true, false);
			});
			filters_popover.sort_mode_changed.connect(() => {
				games_adapter.sort_mode = filters_popover.sort_mode;
				games_adapter.invalidate(false, true);
			});

			add_game_popover.game_added.connect(g => {
				games_adapter.add(g);
				update_view();
			});

			titlebar.pack_start(view);

			if(sources.size > 1)
			{
				#if MANETTE
				titlebar.pack_start(gamepad_image("bumper-left"));
				#endif

				titlebar.pack_start(filter);

				#if MANETTE
				titlebar.pack_start(gamepad_image("bumper-right"));
				#endif
			}

			#if MANETTE
			var gamepad_filters_separator = new Separator(Orientation.VERTICAL);
			gamepad_filters_separator.no_show_all = true;
			gamepad_mode_visible_widgets.add(gamepad_filters_separator);
			titlebar.pack_start(gamepad_filters_separator);
			#endif

			titlebar.pack_start(filters);

			#if MANETTE
			titlebar.pack_start(gamepad_image("y"));
			#endif

			var settings_overlay = new Overlay();
			settings_overlay.add(settings);

			#if MANETTE
			var settings_gamepad_shortcut = gamepad_image("select");
			settings_gamepad_shortcut.halign = Align.CENTER;
			settings_gamepad_shortcut.valign = Align.END;
			settings_overlay.add_overlay(settings_gamepad_shortcut);
			settings_overlay.set_overlay_pass_through(settings_gamepad_shortcut, true);
			#endif

			titlebar.pack_end(settings_overlay);

			titlebar.pack_end(downloads);
			titlebar.pack_end(search);
			titlebar.pack_end(add_game_button);

			#if MANETTE
			var gamepad_shortcuts_separator = new Separator(Orientation.VERTICAL);
			gamepad_shortcuts_separator.no_show_all = true;
			gamepad_mode_visible_widgets.add(gamepad_shortcuts_separator);
			titlebar.pack_end(gamepad_shortcuts_separator);
			titlebar.pack_end(gamepad_image("x", _("Menu")));
			titlebar.pack_end(gamepad_image("b", _("Back")));
			titlebar.pack_end(gamepad_image("a", _("Select")));
			#endif

			status_overlay = new Granite.Widgets.OverlayBar(overlay);
			games_adapter.notify["status"].connect(() => {
				Idle.add(() => {
					if(games_adapter.status != null && games_adapter.status.length > 0)
					{
						status_overlay.label = games_adapter.status;
						status_overlay.active = true;
						status_overlay.show();
					}
					else
					{
						status_overlay.active = false;
						status_overlay.hide();
					}
					return Source.REMOVE;
				}, Priority.LOW);
			});

			show_all();
			games_grid_scrolled.show_all();
			games_grid.show_all();

			stack.set_visible_child(empty_alert);

			view.opacity = 0;
			view.sensitive = false;
			filter.opacity = 0;
			filter.sensitive = false;
			search.opacity = 0;
			search.sensitive = false;
			downloads.opacity = 0;
			filters.opacity = 0;
			filters.sensitive = false;
			add_game_button.opacity = 0;
			add_game_button.sensitive = false;

			Downloader.get_instance().dl_started.connect(dl => {
				Idle.add(() => {
					downloads_list.add(new DownloadProgressView(dl));
					downloads.sensitive = true;
					downloads_count++;

					#if UNITY
					dl.download.status_change.connect(s => {
						Idle.add(() => {
							update_downloads_progress();
							return Source.REMOVE;
						}, Priority.LOW);
					});
					#endif
					return Source.REMOVE;
				}, Priority.LOW);
			});
			Downloader.get_instance().dl_ended.connect(dl => {
				Idle.add(() => {
					downloads_count--;
					if(downloads_count < 0) downloads_count = 0;
					downloads.sensitive = downloads_count > 0;
					if(downloads_count == 0)
					{
						#if GTK_3_22
						downloads_popover.popdown();
						#else
						downloads_popover.hide();
						#endif
					}
					#if UNITY
					update_downloads_progress();
					#endif
					return Source.REMOVE;
				}, Priority.LOW);
			});

			#if MANETTE
			controller_settings = Settings.Controller.get_instance();
			gamepad_mode_hidden_widgets.add(view);
			gamepad_mode_hidden_widgets.add(downloads);
			gamepad_mode_hidden_widgets.add(search);
			gamepad_mode_hidden_widgets.add(add_game_button);

			if(controller_settings.enabled)
			{
				var manette_iterator = manette_monitor.iterate();
				Manette.Device manette_device = null;
				while(manette_iterator.next(out manette_device))
				{
					on_gamepad_connected(manette_device);
				}
				manette_monitor.device_connected.connect(on_gamepad_connected);
				manette_monitor.device_disconnected.connect(on_gamepad_disconnected);
			}
			#endif

			games_adapter.filter_tags = filters_popover.selected_tags;
			games_adapter.sort_mode = filters_popover.sort_mode;

			load_games();
		}

		public override void attach_to_window(MainWindow wnd)
		{
			base.attach_to_window(wnd);

			window.add_action_entries(action_entries, this);
			Application.instance.set_accels_for_action(ACTION_PREFIX + ACTION_SOURCE_PREV,                      { ACCEL_SOURCE_PREV });
			Application.instance.set_accels_for_action(ACTION_PREFIX + ACTION_SOURCE_NEXT,                      { ACCEL_SOURCE_NEXT });
			Application.instance.set_accels_for_action(ACTION_PREFIX + ACTION_SEARCH,                           { ACCEL_SEARCH });
			Application.instance.set_accels_for_action(ACTION_PREFIX + ACTION_FILTERS,                          { ACCEL_FILTERS });
			Application.instance.set_accels_for_action(ACTION_PREFIX + ACTION_DOWNLOADS,                        { ACCEL_DOWNLOADS });
			Application.instance.set_accels_for_action(ACTION_PREFIX + ACTION_SELECT_RANDOM_GAME,               { ACCEL_SELECT_RANDOM_GAME });
			Application.instance.set_accels_for_action(ACTION_PREFIX + ACTION_ADD_GAME,                         { ACCEL_ADD_GAME });
			Application.instance.set_accels_for_action(Application.ACTION_PREFIX + Application.ACTION_SETTINGS, { "F5" }); // Select
		}

		private void window_action_handler(SimpleAction action, Variant? args)
		{
			switch(action.name)
			{
				case ACTION_SOURCE_PREV:
				case ACTION_SOURCE_NEXT:
					var tab = filter.selected + (action.name == ACTION_SOURCE_PREV ? -1 : 1);
					if(tab < 0) tab = (int) filter.n_items - 1;
					else if(tab >= filter.n_items) tab = 0;
					filter.selected = tab;
					break;

				case ACTION_SEARCH:
					search.grab_focus();
					break;

				case ACTION_FILTERS:
					filters.clicked();
					break;

				case ACTION_DOWNLOADS:
					if(downloads.sensitive)
					{
						downloads.clicked();
					}
					break;

				case ACTION_SELECT_RANDOM_GAME:
					/*int index = Random.int_range(0, (int32) games_grid.get_children().length());
					var card = games_grid.get_child_at_index(index);
					if(card != null)
					{
						games_grid.select_child(card);
						if(view.selected == 0)
						{
							card.grab_focus();
						}
					}
					var row = games_list.get_row_at_index(index);
					if(row != null)
					{
						games_list.select_row(row);
						if(view.selected == 1)
						{
							row.grab_focus();
						}
					}*/
					break;

				case ACTION_ADD_GAME:
					add_game_button.clicked();
					break;
			}
		}

		private void update_view()
		{
			show_games();

			var f = filter.selected;
			GameSource? src = null;
			if(f > 0) src = sources[f - 1];
			var games = src == null ? games_grid.get_children().length() : src.games_count;
			titlebar.subtitle = (src == null ? "" : src.name + ": ") + ngettext("%u game", "%u games", games).printf(games);

			if(games_adapter.filter_source != src)
			{
				games_adapter.filter_source = src;
				games_adapter.invalidate(true, false);
			}

			games_list_details.preferred_source = src;

			if(src != null && src.games_count == 0)
			{
				if(src is GameHub.Data.Sources.User.User)
				{
					empty_alert.title = _("No user-added games");
					empty_alert.description = _("Add some games using plus button");
				}
				else
				{
					empty_alert.title = _("No %s games").printf(src.name);
					empty_alert.description = _("Get some Linux-compatible games");
				}
				empty_alert.icon_name = src.icon;
				stack.set_visible_child(empty_alert);
				return;
			}
			else if(search.text.strip().length > 0)
			{
				if(!games_adapter.has_filtered_views())
				{
					empty_alert.title = _("No games matching “%s”").printf(search.text.strip());
					empty_alert.description = null;
					empty_alert.icon_name = null;
					if(src != null)
					{
						empty_alert.title = _("No %1$s games matching “%2$s”").printf(src.name, search.text.strip());
					}
					stack.set_visible_child(empty_alert);
					return;
				}
			}

			var tab = view.selected == 0 ? (Widget) games_grid_scrolled : (Widget) games_list_paned;
			stack.set_visible_child(tab);
			saved_state.games_view = view.selected == 0 ? Settings.GamesView.GRID : Settings.GamesView.LIST;

			Timeout.add(100, () => { select_first_visible_game(); return Source.REMOVE; });
		}

		private void show_games()
		{
			if(view.opacity != 0 || stack.visible_child != empty_alert) return;

			view.set_active(saved_state.games_view == Settings.GamesView.LIST ? 1 : 0);
			stack.set_visible_child(saved_state.games_view == Settings.GamesView.LIST ? (Widget) games_list_paned : (Widget) games_grid_scrolled);

			view.opacity = 1;
			view.sensitive = true;
			filter.opacity = 1;
			filter.sensitive = true;
			search.opacity = 1;
			search.sensitive = true;
			downloads.opacity = 1;
			filters.opacity = 1;
			filters.sensitive = true;
			add_game_button.opacity = 1;
			add_game_button.sensitive = true;
		}

		private void load_games()
		{
			messages.get_children().foreach(c => messages.remove(c));

			games_adapter.load_games(src => {
				if(src.games_count == 0 && src is GameHub.Data.Sources.Steam.Steam)
				{
					var msg = message(_("No games were loaded from Steam. Set your games list privacy to public or use your own Steam API key in settings."), MessageType.WARNING);
					msg.add_button(_("Privacy"), 1);
					msg.add_button(_("Settings"), 2);

					msg.close.connect(() => {
						#if GTK_3_22
						msg.revealed = false;
						#endif
						Timeout.add(250, () => { messages.remove(msg); return Source.REMOVE; });
					});

					msg.response.connect(r => {
						switch(r)
						{
							case 1:
								Utils.open_uri("steam://openurl/https://steamcommunity.com/my/edit/settings");
								break;

							case 2:
								settings.clicked();
								break;

							case ResponseType.CLOSE:
								msg.close();
								break;
						}
					});
				}
			});
		}

		private void add_view_button(string icon, string tooltip)
		{
			var image = new Image.from_icon_name(icon, IconSize.MENU);
			image.tooltip_text = tooltip;
			view.append(image);
		}

		private void add_filter_button(string icon, string tooltip)
		{
			var image = new Image.from_icon_name(icon, IconSize.MENU);
			image.tooltip_text = tooltip;
			filter.append(image);
		}

		private void select_first_visible_game()
		{
			/*var row = games_list.get_selected_row() as GameListRow?;
			if(row != null && games_adapter.filter(row.game)) return;
			row = games_list.get_row_at_y(32) as GameListRow?;
			if(row != null) games_list.select_row(row);

			var cards = games_grid.get_selected_children();
			var card = cards != null && cards.length() > 0 ? cards.first().data as GameCard? : null;
			if(card != null && games_adapter.filter(card.game)) return;
			#if GTK_3_22
			card = games_grid.get_child_at_pos(0, 0) as GameCard?;
			#else
			card = null;
			#endif
			if(card != null)
			{
				games_grid.select_child(card);
				if(!search.has_focus)
				{
					card.grab_focus();
				}
			}*/
		}

		private void search_run_first_matching_game()
		{
			/*if(search.text.strip().length == 0 || !search.has_focus) return;

			if(view.selected == 0)
			{
				#if GTK_3_22
				var card = games_grid.get_child_at_pos(0, 0) as GameCard?;
				if(card != null)
				{
					card.game.run_or_install.begin();
				}
				#endif
			}
			else
			{
				var row = games_list.get_row_at_y(32) as GameListRow?;
				if(row != null)
				{
					row.game.run_or_install.begin();
				}
			}*/
		}

		private InfoBar message(string text, MessageType type=MessageType.OTHER)
		{
			var bar = new InfoBar();
			bar.message_type = type;

			#if GTK_3_22
			bar.revealed = false;
			#endif

			bar.show_close_button = true;
			bar.get_content_area().add(new Label(text));

			messages.add(bar);

			bar.show_all();

			#if GTK_3_22
			bar.revealed = true;
			#endif

			return bar;
		}

		#if UNITY
		private void update_downloads_progress()
		{
			games_adapter.launcher_entry.progress_visible = downloads_count > 0;
			double progress = 0;
			int count = 0;
			downloads_list.foreach(row => {
				var dl_row = row as DownloadProgressView;
				if(dl_row != null)
				{
					progress += dl_row.dl_info.download.status.progress;
					count++;
				}
			});
			games_adapter.launcher_entry.progress = progress / count;
			games_adapter.launcher_entry.count_visible = count > 0;
			games_adapter.launcher_entry.count = count;
		}
		#endif

		#if MANETTE
		private void ui_update_gamepad_mode()
		{
			Idle.add(() => {
				var is_gamepad_connected = connected_gamepads.size > 0 && Gamepad.ButtonPressed;
				var widgets_to_show = is_gamepad_connected ? gamepad_mode_visible_widgets : gamepad_mode_hidden_widgets;
				var widgets_to_hide = is_gamepad_connected ? gamepad_mode_hidden_widgets : gamepad_mode_visible_widgets;
				foreach(var w in widgets_to_show) w.show();
				foreach(var w in widgets_to_hide) w.hide();
				if(is_gamepad_connected)
				{
					view.selected = 0;
					games_grid.grab_focus();
				}
				return Source.REMOVE;
			});
		}

		private void on_gamepad_connected(Manette.Device device)
		{
			debug("[Gamepad] '%s' connected", device.get_name());
			device.button_press_event.connect(on_gamepad_button_press_event);
			device.button_release_event.connect(on_gamepad_button_release_event);
			device.absolute_axis_event.connect(on_gamepad_absolute_axis_event);
			connected_gamepads.add(device);
			gamepad_axes_to_keys_thread();
			ui_update_gamepad_mode();
		}

		private void on_gamepad_disconnected(Manette.Device device)
		{
			debug("[Gamepad] '%s' disconnected", device.get_name());
			connected_gamepads.remove(device);
			ui_update_gamepad_mode();
		}

		private void on_gamepad_button_press_event(Manette.Device device, Manette.Event e)
		{
			uint16 btn;
			if(!e.get_button(out btn)) return;
			on_gamepad_button(btn, true);
		}

		private void on_gamepad_button_release_event(Manette.Event e)
		{
			uint16 btn;
			if(!e.get_button(out btn)) return;
			on_gamepad_button(btn, false);
		}

		private void on_gamepad_button(uint16 btn, bool press)
		{
			if(Gamepad.Buttons.has_key(btn))
			{
				var b = Gamepad.Buttons.get(btn);
				b.emit_key_event(press);
				debug("[Gamepad] Button %s: %s (%s) [%d]", (press ? "pressed" : "released"), b.name, b.long_name, btn);
				ui_update_gamepad_mode();

				if(controller_settings.focus_window && !press && b == Gamepad.BTN_GUIDE && !window.has_focus && !RunnableIsLaunched && !Sources.Steam.Steam.IsAnyAppRunning)
				{
					window.get_window().focus(Gdk.CURRENT_TIME);
				}
			}
		}

		private void on_gamepad_absolute_axis_event(Manette.Event e)
		{
			uint16 axis;
			double value;
			if(!e.get_absolute(out axis, out value)) return;

			if(Gamepad.Axes.has_key(axis))
			{
				Gamepad.Axes.get(axis).value = value;
			}
		}

		private void gamepad_axes_to_keys_thread()
		{
			if(gamepad_axes_to_keys_thread_running) return;
			Utils.thread("GamepadAxesToKeysThread", () => {
				gamepad_axes_to_keys_thread_running = true;
				while(connected_gamepads.size > 0)
				{
					foreach(var axis in Gamepad.Axes.values)
					{
						axis.emit_key_event();
					}
					Thread.usleep(Gamepad.KEY_EVENT_EMIT_INTERVAL);
					ui_update_gamepad_mode();
				}
				Gamepad.reset();
				gamepad_axes_to_keys_thread_running = false;
			});
		}

		private Widget gamepad_image(string icon, string? text=null)
		{
			Widget widget;

			var image = new Image.from_icon_name("controller-button-" + icon, IconSize.LARGE_TOOLBAR);

			if(text != null)
			{
				var label = new HeaderLabel(text);
				var box = new Box(Orientation.HORIZONTAL, 8);
				box.margin_start = box.margin_end = 4;
				box.add(image);
				box.add(label);
				box.show_all();
				widget = box;
			}
			else
			{
				widget = image;
			}

			widget.visible = false;
			widget.no_show_all = true;

			gamepad_mode_visible_widgets.add(widget);
			return widget;
		}
		#endif
	}
}

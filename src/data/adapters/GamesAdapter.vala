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
using Gee;
using GameHub.Data.DB;
using GameHub.Utils;

using GameHub.UI.Views.GamesView;

namespace GameHub.Data.Adapters
{
	public class GamesAdapter: GameHub.UI.Widgets.RecyclerContainer.Adapter
	{
		private Settings.UI ui_settings;
		public bool filter_settings_show_unsupported = true;
		public bool filter_settings_use_compat = true;
		public bool filter_settings_merge = true;

		public GameSource? filter_source = null;
		public ArrayList<Tables.Tags.Tag> filter_tags;
		public Settings.SortMode sort_mode = Settings.SortMode.NAME;
		public string filter_search_query = "";

		private ArrayList<GameSource> sources = new ArrayList<GameSource>();
		private ArrayList<GameSource> loading_sources = new ArrayList<GameSource>();

		private ArrayList<Game> games = new ArrayList<Game>();

		private bool new_games_added = false;

		public string? status { get; private set; default = null; }

		#if UNITY
		public Unity.LauncherEntry launcher_entry;
		public Dbusmenu.Menuitem launcher_menu;
		#endif

		public override int size
		{
			get
			{
				return games.size;
			}
		}

		public override Widget bind(int view_type, int index, Widget? old_widget=null)
		{
			switch(view_type)
			{
				case 0: // Grid
					GameCard card = (GameCard) old_widget ?? new GameCard();
					card.game = games[(int) index];
					return card;

				case 1: // List
					GameListRow row = (GameListRow) old_widget ?? new GameListRow();
					row.game = games[(int) index];
					return row;
			}

			return null;
		}

		public GamesAdapter()
		{
			foreach(var src in GameSources)
			{
				if(src.enabled && src.is_authenticated())
				{
					sources.add(src);
				}
			}

			ui_settings = Settings.UI.get_instance();
			filter_settings_show_unsupported = ui_settings.show_unsupported_games;
			filter_settings_use_compat = ui_settings.use_compat;
			filter_settings_merge = ui_settings.merge_games;

			ui_settings.notify["show-unsupported-games"].connect(() => invalidate());
			ui_settings.notify["use-proton"].connect(() => invalidate());
			ui_settings.notify["merge-games"].connect(() => invalidate());


			#if UNITY
			launcher_entry = Unity.LauncherEntry.get_for_desktop_id(ProjectConfig.PROJECT_NAME + ".desktop");
			setup_launcher_menu();
			#endif
		}

		public void invalidate(bool filter=true, bool sort=true)
		{
			filter_settings_show_unsupported = ui_settings.show_unsupported_games;
			filter_settings_use_compat = ui_settings.use_compat;
			filter_settings_merge = ui_settings.merge_games;
			if(filter)
			{

			}
			if(sort)
			{

			}
		}

		public void load_games(Utils.FutureResult<GameSource> loaded_callback)
		{
			Utils.thread("GamesAdapterLoad", () => {
				foreach(var src in sources)
				{
					loading_sources.add(src);
					update_loading_status();
					src.load_games.begin(add, () => {
						/*Idle.add(() => {
							changed();
							return Source.REMOVE;
						}, Priority.LOW);*/
					}, (obj, res) => {
						src.load_games.end(res);
						loading_sources.remove(src);
						update_loading_status();
						loaded_callback(src);
						if(loading_sources.size == 0 && new_games_added)
						{
							if(new_games_added)
							{
								merge_games();
							}
							else
							{
								status = null;
							}
						}
					});
				}
			});
		}

		public void add(Game game, bool is_cached=false)
		{
			games.add(game);

			if(!is_cached)
			{
				new_games_added = true;
			}

			Idle.add(() => {
				changed();
				return Source.REMOVE;
			}, Priority.LOW);

			if(game is Sources.User.UserGame)
			{
				((Sources.User.UserGame) game).removed.connect(() => {
					remove(game);
				});
			}

			#if UNITY
			add_game_to_launcher_favorites_menu(game);
			#endif
		}

		public void remove(Game game)
		{
			games.remove(game);
			Idle.add(() => {
				changed();
				return Source.REMOVE;
			}, Priority.LOW);
		}

		public bool filter(Game game)
		{
			if(!filter_settings_show_unsupported && !game.is_supported(null, filter_settings_use_compat)) return false;

			bool same_src = (filter_source == null || game == null || filter_source == game.source);
			bool merged_src = false;

			ArrayList<Game>? merges = null;

			if(filter_settings_merge)
			{
				merges = Tables.Merges.get(game);
				if(!same_src && merges != null && merges.size > 0)
				{
					foreach(var g in merges)
					{
						if(g.source == filter_source)
						{
							merged_src = true;
							break;
						}
					}
				}
			}

			bool tags_all_enabled = filter_tags == null || filter_tags.size == 0 || filter_tags.size == Tables.Tags.TAGS.size;
			bool tags_all_except_hidden_enabled = filter_tags != null && filter_tags.size == Tables.Tags.TAGS.size - 1 && !(Tables.Tags.BUILTIN_HIDDEN in filter_tags);
			bool tags_match = false;
			bool tags_match_merged = false;

			if(!tags_all_enabled)
			{
				foreach(var tag in filter_tags)
				{
					tags_match = game.has_tag(tag);
					if(tags_match) break;
				}
				if(!tags_match && merges != null && merges.size > 0)
				{
					foreach(var g in merges)
					{
						foreach(var tag in filter_tags)
						{
							tags_match_merged = g.has_tag(tag);
							if(tags_match_merged) break;
						}
					}
				}
			}

			bool hidden = game.has_tag(Tables.Tags.BUILTIN_HIDDEN) && (filter_tags == null || filter_tags.size == 0 || !(Tables.Tags.BUILTIN_HIDDEN in filter_tags));

			return (same_src || merged_src) && (tags_all_enabled || tags_all_except_hidden_enabled || tags_match || tags_match_merged) && !hidden && Utils.strip_name(filter_search_query).casefold() in Utils.strip_name(game.name).casefold();
		}

		public int sort(Game game1, Game game2)
		{
			if(game1 != null && game2 != null)
			{
				var s1 = game1.status.state;
				var s2 = game2.status.state;

				var f1 = game1.has_tag(Tables.Tags.BUILTIN_FAVORITES);
				var f2 = game2.has_tag(Tables.Tags.BUILTIN_FAVORITES);

				if(f1 && !f2) return -1;
				if(f2 && !f1) return 1;

				if(s1 == Game.State.DOWNLOADING && s2 != Game.State.DOWNLOADING) return -1;
				if(s1 != Game.State.DOWNLOADING && s2 == Game.State.DOWNLOADING) return 1;
				if(s1 == Game.State.INSTALLING && s2 != Game.State.INSTALLING) return -1;
				if(s1 != Game.State.INSTALLING && s2 == Game.State.INSTALLING) return 1;
				if(s1 == Game.State.INSTALLED && s2 != Game.State.INSTALLED) return -1;
				if(s1 != Game.State.INSTALLED && s2 == Game.State.INSTALLED) return 1;

				switch(sort_mode)
				{
					case Settings.SortMode.LAST_LAUNCH:
						if(game1.last_launch > game2.last_launch) return -1;
						if(game1.last_launch < game2.last_launch) return 1;
						break;

					case Settings.SortMode.PLAYTIME:
						if(game1.playtime > game2.playtime) return -1;
						if(game1.playtime < game2.playtime) return 1;
						break;
				}

				return game1.normalized_name.collate(game2.normalized_name);
			}
			return 0;
		}

		public bool has_filtered_views()
		{
			/*foreach(var card in grid.get_children())
			{
				if(filter(((GameCard) card).game))
				{*/
					return true;
				/*}
			}
			return false;*/
		}

		private void merge_games()
		{
			if(!filter_settings_merge) return;
			Utils.thread("GamesAdapterMerge", () => {
				status = _("Merging games");
				foreach(var src in sources)
				{
					merge_games_from(src);
				}
				status = null;
			});
		}

		private void merge_games_from(GameSource src)
		{
			if(!filter_settings_merge) return;
			debug("[Merge] Merging %s games", src.name);
			status = _("Merging games from %s").printf(src.name);
			foreach(var game in src.games)
			{
				merge_game(game);
			}
		}

		private void merge_game(Game game)
		{
			if(!filter_settings_merge || game is Sources.GOG.GOGGame.DLC) return;
			foreach(var src in sources)
			{
				foreach(var game2 in src.games)
				{
					merge_game_with_game(src, game, game2);
				}
			}
		}

		private void merge_game_with_game(GameSource src, Game game, Game game2)
		{
			if(Game.is_equal(game, game2) || game2 is Sources.GOG.GOGGame.DLC) return;

			bool name_match_exact = game.normalized_name.casefold() == game2.normalized_name.casefold();
			bool name_match_fuzzy_prefix = game.source != src
			                  && (Utils.strip_name(game.name, ":", true).casefold().has_prefix(game2.normalized_name.casefold() + ":")
			                  || Utils.strip_name(game2.name, ":", true).casefold().has_prefix(game.normalized_name.casefold() + ":"));
			if(name_match_exact || name_match_fuzzy_prefix)
			{
				Tables.Merges.add(game, game2);
				debug("[Merge] Merging '%s' (%s) with '%s' (%s)", game.name, game.full_id, game2.name, game2.full_id);
				remove(game2);
			}
		}

		private void update_loading_status()
		{
			if(loading_sources.size > 0)
			{
				string[] src_names = {};
				foreach(var s in loading_sources)
				{
					src_names += s.name;
				}
				status = _("Loading games from %s").printf(string.joinv(", ", src_names));
			}
			else
			{
				status = null;
			}
		}

		#if UNITY
		private void setup_launcher_menu()
		{
			launcher_menu = new Dbusmenu.Menuitem();
			launcher_entry.quicklist = launcher_menu;
		}

		/*private Dbusmenu.Menuitem launcher_menu_separator()
		{
			var separator = new Dbusmenu.Menuitem();
			separator.property_set(Dbusmenu.MENUITEM_PROP_TYPE, Dbusmenu.CLIENT_TYPES_SEPARATOR);
			return separator;
		}*/

		private void add_game_to_launcher_favorites_menu(Game game)
		{
			var added = false;
			Dbusmenu.Menuitem? item = null;

			SourceFunc update = () => {
				Idle.add(() => {
					var favorite = game.has_tag(Tables.Tags.BUILTIN_FAVORITES);
					if(!added && favorite)
					{
						if(item == null)
						{
							item = new Dbusmenu.Menuitem();
							item.property_set(Dbusmenu.MENUITEM_PROP_LABEL, game.name);
							item.item_activated.connect(() => { game.run_or_install.begin(); });
						}
						launcher_menu.child_append(item);
						added = true;
					}
					else if(added && !favorite)
					{
						if(item != null)
						{
							launcher_menu.child_delete(item);
						}
						added = false;
					}
					return Source.REMOVE;
				}, Priority.LOW);
				return Source.REMOVE;
			};

			game.tags_update.connect(() => update());
			update();
		}
		#endif
	}
}

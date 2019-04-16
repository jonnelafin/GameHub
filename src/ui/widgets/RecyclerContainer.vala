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
using Gee;

namespace GameHub.UI.Widgets
{
	public class RecyclerContainer: Container, Scrollable
	{
		private RecyclerContainer.Adapter adapter;
		private int view_type;

		private LinkedList<Widget> widgets = new LinkedList<Widget>();
		private LinkedList<Widget> pool    = new LinkedList<Widget>();

		public int columns = 1;
		public int min_column_width = -1;
		public int max_column_width = -1;

		public int width { get; private set; }
		public int height { get; private set; }

		private double offset;

		private int adapter_start;
		private int adapter_end;

		private Adjustment? _vadjustment = null;
		private ulong signalid_vadjustment_value_change;
		public Adjustment hadjustment { get; set; }
		public Adjustment vadjustment
		{
			get
			{
				return _vadjustment;
			}
			set
			{
				if(_vadjustment != null)
				{
					_vadjustment.disconnect(signalid_vadjustment_value_change);
				}
				_vadjustment = value;
				signalid_vadjustment_value_change = _vadjustment.value_changed.connect(() => {
					//last_value = vadjustment.value;
					queue_allocate();
				});
			}
		}

		public ScrollablePolicy hscroll_policy { get; set; }
		public ScrollablePolicy vscroll_policy { get; set; }

		public RecyclerContainer(RecyclerContainer.Adapter adapter, int view_type=0, int min_column_width=-1, int max_column_width=-1)
		{
			base.set_has_window(false);
			base.set_can_focus(true);
			base.set_redraw_on_allocate(false);

			this.adapter = adapter;
			this.view_type = view_type;

			this.min_column_width = min_column_width;
			this.max_column_width = max_column_width;

			adapter.changed.connect(() => {
				for(int i = widgets.size - 1; i >= 0; i--)
				{
					remove_child(i);
				}
				adapter_start = 0;
				adapter_end = adapter_start;
				offset = 0;
				queue_allocate();
			});

			add_events(EventMask.ALL_EVENTS_MASK);
		}

		private Widget get_widget(int index)
		{
			if(index < 0 || index >= adapter.size)
			{
				warning("[Recycler.get_widget] Index out of bounds: %d. Size: %d", index, adapter.size);
			}

			Widget? old_widget = null;
			Widget? new_widget = null;

			if(pool.size > 0)
			{
				old_widget = pool.remove_at(pool.size - 1);
			}

			new_widget = adapter.bind(view_type, index, old_widget);

			assert_nonnull(new_widget);
			if(old_widget != null) assert(old_widget == new_widget);

			return new_widget;
		}

		private void insert_child(Widget widget, int index)
		{
			if(index < 0)
			{
				error("[Recycler.insert_child] Index is less than zero: %d", index);
				assert_not_reached();
			}
			assert_nonnull(widget);

			if(widget.parent == null) widget.parent = this;
			widget.show_all();
			widgets.insert(index, widget);
		}

		private void remove_child(int index)
		{
			if(index < 0 || index >= widgets.size) return;

			var widget = widgets.remove_at(index);
			widget.visible = false;
			pool.add(widget);
		}

		private inline int row_height
		{
			get
			{
				if(widgets.size == 0) return 1;
				int height;
				widgets[0].get_preferred_height_for_width(width / columns, out height, null);
				return height;
			}
		}

		private inline int row_y(int row)
		{
			return row_height * row;
		}

		private inline int content_offset
		{
			get
			{
				return (int) (-vadjustment.value + offset);
			}
		}

		private inline int content_height
		{
			get
			{
				return row_height * widgets.size / columns;
			}
		}

		private inline int full_content_height
		{
			get
			{
				return row_height * adapter.size / columns;
			}
		}

		private void set_vadjustment_value(double new_value)
		{
			SignalHandler.block(this, signalid_vadjustment_value_change);
			vadjustment.value = new_value;
			SignalHandler.unblock(this, signalid_vadjustment_value_change);
		}

		private void set_vadjustment_value_and_adjust_offset(double new_value)
		{
			var value = vadjustment.value;
			set_vadjustment_value(new_value);
			offset -= (value - new_value);
		}

		private void adjust()
		{
			vadjustment.freeze_notify();

			if(vadjustment.upper != full_content_height)
			{
				vadjustment.upper = full_content_height + margin_top + margin_bottom;
			}
			else if(full_content_height == 0)
			{
				vadjustment.upper = height + margin_top + margin_bottom;
			}

			if((int) vadjustment.page_size != height)
			{
				vadjustment.page_size = height;
			}

			var max = int.max(0, full_content_height - height);
			if(vadjustment.value > max)
			{
				set_vadjustment_value_and_adjust_offset(max);
			}

			vadjustment.thaw_notify();
		}

		private void show_widgets()
		{
			if(vadjustment == null || adapter == null || adapter.size == 0 || height < 1 || row_height < 1) return;

			if(widgets.size == 0)
			{
				warning("WS == 0");
				adapter_start = 0;
				adapter_end = 1;
				insert_child(get_widget(0), 0);
			}
			else
			{
				var scroll_percentage = vadjustment.value / int.max((int) vadjustment.upper, full_content_height);
				var rows_count = (int) Math.ceilf(adapter.size / columns);
				var first_row_index = (int) (rows_count * scroll_percentage);
				var visible_rows_count = (int) Math.ceilf(height / row_height);
				var min_row_index = int.max(0, first_row_index - 1);
				var max_row_index = int.min(rows_count, first_row_index + visible_rows_count + 2);

				var start = int.max(0, columns * min_row_index);
				var end = int.min(adapter.size - 1, columns * max_row_index);

				offset = min_row_index * row_height;

				/*warning("scroll: %f / %f = %f", vadjustment.value, vadjustment.upper, scroll_percentage);
				warning("rows: %d", rows_count);
				warning("first visible row: %d", first_row_index);
				warning("visible rows: %d", visible_rows_count);
				warning("min row: %d", min_row_index);
				warning("max row: %d", max_row_index);
				warning("start: %d; end: %d", start, end);
				warning("as: %d; ae: %d", adapter_start, adapter_end);*/

				while(start > adapter_start)
				{
					adapter_start++;
					remove_child(0);
					debug(" rm begin: start: %d; end: %d; as: %d; ae: %d", start, end, adapter_start, adapter_end);
				}
				while(start < adapter_start)
				{
					adapter_start--;
					insert_child(get_widget(adapter_start), 0);
					debug("ins begin: start: %d; end: %d; as: %d; ae: %d", start, end, adapter_start, adapter_end);
				}
				while(adapter_end > end)
				{
					adapter_end--;
					remove_child(widgets.size - 1);
					debug("   rm end: start: %d; end: %d; as: %d; ae: %d", start, end, adapter_start, adapter_end);
				}
				while(adapter_end < end)
				{
					adapter_end++;
					insert_child(get_widget(adapter_end), widgets.size);
					debug("  ins end: start: %d; end: %d; as: %d; ae: %d", start, end, adapter_start, adapter_end);
				}
			}

			if(vadjustment.upper != full_content_height + margin_top + margin_bottom)
			{
				vadjustment.upper = full_content_height + margin_top + margin_bottom;
				set_vadjustment_value_and_adjust_offset(int.max(0, int.min(full_content_height - height, (int) (adapter_start * row_height) - content_offset)));
			}

			adjust();
		}

		public override void size_allocate(Allocation allocation)
		{
			width = allocation.width;
			height = allocation.height;

			var new_columns = columns;

			if(min_column_width > 0 && max_column_width > 0)
			{
				new_columns = width / min_column_width;
			}
			else
			{
				new_columns = 1;
			}

			if(new_columns != columns)
			{
				columns = new_columns;
				adapter_start = 0;
				adapter_end = 0;
				set_vadjustment_value(0);
				while(widgets.size > 0) remove_child(0);
			}

			show_widgets();

			if(widgets.size > 0)
			{
				Allocation child_allocation = Allocation();

				child_allocation.width = allocation.width / columns;
				child_allocation.height = row_height;

				for(var i = 0; i < widgets.size; i++)
				{
					child_allocation.x = margin_start + ((i % columns) * child_allocation.width);
					child_allocation.y = margin_top + content_offset + ((i / columns) * child_allocation.height);
					widgets[i].size_allocate(child_allocation);
				}
			}
		}

		public override void forall_internal(bool include_internals, Gtk.Callback callback)
		{
			foreach(var child in widgets)
			{
				callback(child);
			}
			if(include_internals)
			{
				foreach(var child in pool)
				{
					callback(child);
				}
			}
		}

		public bool get_border(out Border border)
		{
			return false;
		}

		public abstract class Adapter: Object
		{
			public abstract int size { get; }

			public signal void changed();

			public abstract Widget bind(int view_type, int index, Widget? old_widget=null);
		}
	}
}

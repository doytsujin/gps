------------------------------------------------------------------------------
--                                  G P S                                   --
--                                                                          --
--                     Copyright (C) 2000-2015, AdaCore                     --
--                                                                          --
-- This is free software;  you can redistribute it  and/or modify it  under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  This software is distributed in the hope  that it will be useful, --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for  more details.  You should have  received  a copy of the GNU --
-- General  Public  License  distributed  with  this  software;   see  file --
-- COPYING3.  If not, go to http://www.gnu.org/licenses for a complete copy --
-- of the license.                                                          --
------------------------------------------------------------------------------

with Ada.Calendar;              use Ada.Calendar;
with Ada.Strings.Unbounded;     use Ada.Strings.Unbounded;
with Ada.Strings.Equal_Case_Insensitive; use Ada.Strings;
with Ada.Text_IO;               use Ada.Text_IO;
with Ada.Unchecked_Deallocation;

with GNAT.Directory_Operations; use GNAT.Directory_Operations;
with GNAT.OS_Lib;               use GNAT.OS_Lib;
with GNATCOLL.Utils;            use GNATCOLL.Utils;
with GNATCOLL.VFS;              use GNATCOLL.VFS;

with Glib.Object;               use Glib.Object;
with Glib.Properties;           use Glib.Properties;
with Glib.Main;
with Glib.Values;               use Glib.Values;

with Gdk;                       use Gdk;
with Gdk.Cursor;                use Gdk.Cursor;
with Gdk.Device;                use Gdk.Device;
with Gdk.Event;                 use Gdk.Event;
with Gdk.Keyval;                use Gdk.Keyval;
with Gdk.Main;                  use Gdk.Main;
with Gdk.Pixbuf;                use Gdk.Pixbuf;
with Gdk.RGBA;                  use Gdk.RGBA;
with Gdk.Types.Keysyms;         use Gdk.Types.Keysyms;
with Gdk.Types;                 use Gdk.Types;
with Gdk.Window;                use Gdk.Window;

with Gtk.Accel_Map;             use Gtk.Accel_Map;
with Gtk.Alignment;             use Gtk.Alignment;
with Gtk.Bin;                   use Gtk.Bin;
with Gtk.Box;                   use Gtk.Box;
with Gtk.Button;                use Gtk.Button;
with Gtk.Cell_Renderer;         use Gtk.Cell_Renderer;
with Gtk.Cell_Renderer_Pixbuf;  use Gtk.Cell_Renderer_Pixbuf;
with Gtk.Container;             use Gtk.Container;
with Gtk.Dialog;                use Gtk.Dialog;
with Gtk.Enums;                 use Gtk.Enums;
with Gtk.Event_Box;             use Gtk.Event_Box;
with Gtk.GEntry;                use Gtk.GEntry;
with Gtk.Handlers;              use Gtk.Handlers;
with Gtk.Image;                 use Gtk.Image;
with Gtk.Label;                 use Gtk.Label;
with Gtk.List_Store;            use Gtk.List_Store;
with Gtk.Menu;                  use Gtk.Menu;
with Gtk.Menu_Bar;              use Gtk.Menu_Bar;
with Gtk.Menu_Item;             use Gtk.Menu_Item;
with Gtk.Menu_Shell;            use Gtk.Menu_Shell;
with Gtk.Stock;                 use Gtk.Stock;
with Gtk.Text_Buffer;           use Gtk.Text_Buffer;
with Gtk.Text_Iter;             use Gtk.Text_Iter;
with Gtk.Text_Mark;             use Gtk.Text_Mark;
with Gtk.Text_Tag;              use Gtk.Text_Tag;
with Gtk.Text_View;             use Gtk.Text_View;
with Gtk.Tree_Model;            use Gtk.Tree_Model;
with Gtk.Tree_Selection;        use Gtk.Tree_Selection;
with Gtk.Tree_Store;            use Gtk.Tree_Store;
with Gtk.Tree_View;             use Gtk.Tree_View;
with Gtk.Tree_View_Column;      use Gtk.Tree_View_Column;
with Gtk.Widget;                use Gtk.Widget;
with Gtk.Window;                use Gtk.Window;

with Gtkada.Handlers;           use Gtkada.Handlers;

with Config;                    use Config;
with String_List_Utils;         use String_List_Utils;
with String_Utils;              use String_Utils;
with Glib_String_Utils;         use Glib_String_Utils;
with System;                    use System;
with GNATCOLL.Traces;                    use GNATCOLL.Traces;
with File_Utils;                use File_Utils;
with Ada.Containers.Ordered_Sets;

package body GUI_Utils is

   Me : constant Trace_Handle := Create ("GUI_Utils");

   Busy_Cursor : Gdk.Gdk_Cursor;
   --  A global variable, allocated once and never freed

   type Contextual_Menu_Data is record
      Create  : Contextual_Menu_Create;
      Widget  : Gtk_Widget;
   end record;

   type Model_Column is record
      Model   : Gtk_Tree_Model;
      Column  : Glib.Gint;
   end record;

   package Contextual_Callback is new Gtk.Handlers.User_Return_Callback
     (Gtk_Widget_Record, Boolean, Contextual_Menu_Data);
   package Tree_Column_Callback is new Gtk.Handlers.User_Callback
     (Glib.Object.GObject_Record, Model_Column);

--     package Widget_Sources is new Glib.Main.Generic_Sources (Gtk_Widget);
--
   function Idle_Grab_Focus (Widget : Gtk_Widget) return Boolean;
   pragma Unreferenced (Idle_Grab_Focus);
   --  Give the focus to widget (called from an idle loop)

   procedure Toggle_Callback
     (Render : access GObject_Record'Class;
      Params : Glib.Values.GValues;
      Data   : Model_Column);
   --  Called when a toggle renderer is clicked on

   function Button_Press_For_Contextual_Menu
     (Widget : access Gtk_Widget_Record'Class;
      Event  : Gdk.Event.Gdk_Event;
      Data   : Contextual_Menu_Data) return Boolean;
   --  Callback that pops up the contextual menu if needed

   function Key_Press_For_Contextual_Menu
     (Widget : access Gtk_Widget_Record'Class;
      Event  : Gdk.Event.Gdk_Event;
      Data   : Contextual_Menu_Data) return Boolean;
   --  Callback that pops up the contextual menu if needed

   procedure Radio_Callback
     (Model  : access GObject_Record'Class;
      Params : Glib.Values.GValues;
      Data   : Glib.Gint);
   --  Callback for the toggle renderer

   procedure Edited_Callback
     (Model  : access GObject_Record'Class;
      Params : Glib.Values.GValues;
      Data   : Glib.Gint);
   --  Callback for the editable renderer

   function "<" (A, B : Gtk_Window) return Boolean is
     (A.all'Address < B.all'Address);

   package Windows_Sets is
     new Ada.Containers.Ordered_Sets (Gtk_Window);

   function Get_MDI_Windows
     (MDI : not null access Gtkada.MDI.MDI_Window_Record'Class)
      return Windows_Sets.Set;

   ---------------------------
   -- Add_Unique_List_Entry --
   ---------------------------

   function Add_Unique_List_Entry
     (List    : access Gtk.List_Store.Gtk_List_Store_Record'Class;
      Text    : String;
      Prepend : Boolean := False;
      Col     : Gint := 0) return Gtk.Tree_Model.Gtk_Tree_Iter
   is
      Iter : Gtk_Tree_Iter;
   begin
      Iter := List.Get_Iter_First;

      while Iter /= Null_Iter loop
         if List.Get_String (Iter, Col) = Text then
            return Iter;
         end if;

         List.Next (Iter);
      end loop;

      if Prepend then
         List.Prepend (Iter);
      else
         List.Append (Iter);
      end if;

      List.Set (Iter, Col, Text);

      return Iter;
   end Add_Unique_List_Entry;

   ----------------------------
   -- Add_Unique_Combo_Entry --
   ----------------------------

   procedure Add_Unique_Combo_Entry
     (Combo        : access Gtk.Combo_Box.Gtk_Combo_Box_Record'Class;
      Text         : String;
      Select_Text  : Boolean := False;
      Prepend      : Boolean := False;
      Col          : Gint := 0;
      Case_Sensitive : Boolean := True)
   is
      Iter : Gtk_Tree_Iter;
      pragma Unreferenced (Iter);
   begin
      Iter := Add_Unique_Combo_Entry
        (Combo, Text, Select_Text, Prepend, Col, Case_Sensitive);
   end Add_Unique_Combo_Entry;

   ----------------------------
   -- Add_Unique_Combo_Entry --
   ----------------------------

   function Add_Unique_Combo_Entry
     (Combo        : access Gtk.Combo_Box.Gtk_Combo_Box_Record'Class;
      Text         : String;
      Select_Text  : Boolean := False;
      Prepend      : Boolean := False;
      Col          : Gint := 0;
      Case_Sensitive : Boolean := True) return Gtk_Tree_Iter
   is
      Iter  : Gtk_Tree_Iter;
      Model : constant Gtk_List_Store := -Gtk.Combo_Box.Get_Model (Combo);
   begin
      Iter := Get_Iter_First (Model);

      while Iter /= Null_Iter loop
         declare
            Str : String renames Model.Get_String (Iter, Col);
         begin
            exit when Str = Text
              or else (not Case_Sensitive
                       and then Equal_Case_Insensitive (Text, Str));
         end;

         Model.Next (Iter);
      end loop;

      if Iter = Null_Iter then
         if Prepend then
            Gtk.List_Store.Prepend (Model, Iter);
         else
            Gtk.List_Store.Append (Model, Iter);
         end if;

         Model.Set (Iter, Col, Text);
      end if;

      if Select_Text then
         Gtk.Combo_Box.Set_Active_Iter (Combo, Iter);
      end if;

      return Iter;
   end Add_Unique_Combo_Entry;

   ---------------------
   -- Set_Active_Text --
   ---------------------

   procedure Set_Active_Text
     (Combo        : access Gtk.Combo_Box.Gtk_Combo_Box_Record'Class;
      Text         : String;
      Col          : Gint := 0;
      Case_Sensitive : Boolean := True)
   is
      Iter  : Gtk_Tree_Iter;
      Model : constant Gtk_List_Store := -Combo.Get_Model;
   begin
      Iter := Get_Iter_First (Model);

      while Iter /= Null_Iter loop
         if (Case_Sensitive and then Model.Get_String (Iter, Col) = Text)
           or else
             (not Case_Sensitive
              and then
                Equal_Case_Insensitive (Model.Get_String (Iter, Col), Text))
         then
            Combo.Set_Active_Iter (Iter);
            return;
         end if;

         Model.Next (Iter);
      end loop;

      --  No such existing item found. If the combo has an entry, let's enter
      --  the text in there

      if Combo.Get_Has_Entry then
         Gtk_Entry (Combo.Get_Child).Set_Text (Text);
      end if;
   end Set_Active_Text;

   ---------------------
   -- Set_Busy_Cursor --
   ---------------------

   procedure Set_Busy_Cursor
     (Window        : Gdk.Gdk_Window;
      Busy          : Boolean := True;
      Force_Refresh : Boolean := False) is
   begin
      if Window /= null then
         if Busy then
            if Busy_Cursor = null then
               --  We create the cursor only once, since this is both more
               --  efficient and avoids some memory leaks (for some reason, it
               --  seems that gtk+ is not properly deallocating cursors, for
               --  windows that were created while the busy cursor was active).
               Gdk_New (Busy_Cursor, Watch);
            end if;
            Set_Cursor (Window, Busy_Cursor);
         else
            Set_Cursor (Window, null);
         end if;

         if Force_Refresh then
            Gdk.Main.Flush;
         end if;
      end if;
   end Set_Busy_Cursor;

   -----------------------------------
   -- Key_Press_For_Contextual_Menu --
   -----------------------------------

   function Key_Press_For_Contextual_Menu
     (Widget : access Gtk_Widget_Record'Class;
      Event  : Gdk.Event.Gdk_Event;
      Data   : Contextual_Menu_Data) return Boolean
   is
      Menu : Gtk_Menu;

   begin
      if Get_Key_Val (Event) = GDK_Menu then
         Menu := Data.Create (Widget, Event);

         if Menu /= null then
            Grab_Focus (Widget);
            Show_All (Menu);
            Menu.Set_Can_Focus (True);
            Menu.Grab_Focus;
            Popup (Menu,
                   Button        => 0,
                   Activate_Time => Gdk.Event.Get_Time (Event));

            Emit_Stop_By_Name (Widget, "key_press_event");
            return True;
         end if;
      end if;

      return False;

   exception
      when E : others =>
         Trace (Me, E);
         return False;
   end Key_Press_For_Contextual_Menu;

   --------------------------------------
   -- Button_Press_For_Contextual_Menu --
   --------------------------------------

   function Button_Press_For_Contextual_Menu
     (Widget : access Gtk_Widget_Record'Class;
      Event  : Gdk.Event.Gdk_Event;
      Data   : Contextual_Menu_Data) return Boolean
   is
      Menu                : Gtk_Menu;
      Time_Before_Factory : Time;

   begin
      if Get_Button (Event) = 3
        and then Get_Event_Type (Event) = Button_Press
      then
         if Host = Windows then
            Time_Before_Factory := Clock;
         end if;

         Menu := Data.Create (Widget, Event);

         if Menu /= null then
            Grab_Focus (Widget);
            Show_All (Menu);

            --  Here we are calling Popup with an Activate_Time adjusted
            --  by the time to execute the menu factory.
            --
            --  The addition of the time to execute the menu factory is an
            --  adjustment needed under Windows, because the time of events is
            --  written at the time at which they reach the Gtk main loop,
            --  whereas, under X11, they are written at the time they occur.
            --  The regressions causes menus that have an expensive factory
            --  (such as the first contextual menu on an entity, before any
            --  xref information has been loaded) to disappear immediately if
            --  they are created with a simple click.

            if Host = Windows then
               Popup (Menu,
                      Button        => Gdk.Event.Get_Button (Event),
                      Activate_Time => Gdk.Event.Get_Time (Event)
                        + Guint32 ((Clock - Time_Before_Factory) * 1000));
            else
               Popup (Menu,
                      Button        => Gdk.Event.Get_Button (Event),
                      Activate_Time => Gdk.Event.Get_Time (Event));
            end if;

            Emit_Stop_By_Name (Widget, "button_press_event");
            return True;
         end if;
      end if;

      return False;

   exception
      when E : others =>
         Trace (Me, E);
         return False;
   end Button_Press_For_Contextual_Menu;

   ------------------------------
   -- Register_Contextual_Menu --
   ------------------------------

   procedure Register_Contextual_Menu
     (Widget       : access Gtk_Widget_Record'Class;
      Menu_Create  : Contextual_Menu_Create) is
   begin
      --  If the widget doesn't have a window, it might not work. But then, if
      --  the children have windows and do not handle the event, this might get
      --  propagated, and the contextual menu will be properly displayed.
      --  So we just avoid a gtk warning

      if Widget.Get_Has_Window then
         Add_Events
           (Widget,
            Button_Press_Mask or Button_Release_Mask or Key_Press_Mask);
      end if;

      Contextual_Callback.Connect
        (Widget, Signal_Button_Press_Event,
         Contextual_Callback.To_Marshaller
           (Button_Press_For_Contextual_Menu'Access),
         (Menu_Create, Gtk_Widget (Widget)));
      Contextual_Callback.Connect
        (Widget, Signal_Key_Press_Event,
         Contextual_Callback.To_Marshaller
           (Key_Press_For_Contextual_Menu'Access),
         (Menu_Create, Gtk_Widget (Widget)));
   end Register_Contextual_Menu;

   ---------------------------
   -- User_Contextual_Menus --
   ---------------------------

   package body User_Contextual_Menus is

      package Pop is new Gtk.Menu.Popup_User_Data (Gdk.Event.Gdk_Event);

      procedure Contextual_Menu_Position_Callback
        (Menu : not null access Gtk_Menu_Record'Class;
         X : in out Gint;
         Y : in out Gint;
         Push_In : out Boolean;
         Val : Gdk.Event.Gdk_Event);

      function Button_Press_For_Contextual_Menu
        (Widget : access Gtk_Widget_Record'Class;
         Event  : Gdk.Event.Gdk_Event;
         User   : Callback_User_Data) return Boolean;

      function Key_Press_For_Contextual_Menu
        (Widget : access Gtk_Widget_Record'Class;
         Event  : Gdk.Event.Gdk_Event;
         User   : Callback_User_Data) return Boolean;

      -----------------------------------
      -- Key_Press_For_Contextual_Menu --
      -----------------------------------

      function Key_Press_For_Contextual_Menu
        (Widget : access Gtk_Widget_Record'Class;
         Event  : Gdk.Event.Gdk_Event;
         User   : Callback_User_Data) return Boolean
      is
         Menu : Gtk_Menu;

      begin
         if Get_Key_Val (Event) = GDK_Menu then
            Menu := User.Menu_Create (User.User, Event);

            if Menu /= null then
               Show_All (Menu);
               Menu.Set_Can_Focus (True);
               Menu.Grab_Focus;
               Popup (Menu,
                      Button        => 0,
                      Activate_Time => Gdk.Event.Get_Time (Event));
               Emit_Stop_By_Name (Widget, "key_press_event");
               return True;
            end if;
         end if;

         return False;
      end Key_Press_For_Contextual_Menu;

      ---------------------------------------
      -- Contextual_Menu_Position_Callback --
      ---------------------------------------

      procedure Contextual_Menu_Position_Callback
        (Menu : not null access Gtk_Menu_Record'Class;
         X : in out Gint;
         Y : in out Gint;
         Push_In : out Boolean;
         Val : Gdk.Event.Gdk_Event)
      is
         pragma Unreferenced (Menu);
      begin
         X := Gint (Val.Button.X_Root);
         Y := Gint (Val.Button.Y_Root);
         Push_In := False;
      end Contextual_Menu_Position_Callback;

      --------------------------------------
      -- Button_Press_For_Contextual_Menu --
      --------------------------------------

      function Button_Press_For_Contextual_Menu
        (Widget : access Gtk_Widget_Record'Class;
         Event  : Gdk.Event.Gdk_Event;
         User   : Callback_User_Data) return Boolean
      is
         Menu                : Gtk_Menu;
         Time_Before_Factory : Time;

      begin
         if Get_Button (Event) = 3
           and then Get_Event_Type (Event) = Button_Press
         then
            if Host = Windows then
               Time_Before_Factory := Clock;
            end if;

            Menu := User.Menu_Create (User.User, Event);

            if Menu /= null then
               Grab_Focus (Widget);
               Show_All (Menu);

               --  See comments in Button_Press_For_Contextual_Menu above

               if Host = Windows then
                  Pop.Popup (Menu,
                         Button        => Gdk.Event.Get_Button (Event),
                         Activate_Time => Gdk.Event.Get_Time (Event)
                         + Guint32 ((Clock - Time_Before_Factory) * 1000),
                         Func => Contextual_Menu_Position_Callback'Access,
                         Data => Event);
               else
                  Popup (Menu,
                         Button        => Gdk.Event.Get_Button (Event),
                         Activate_Time => Gdk.Event.Get_Time (Event));
               end if;

               Emit_Stop_By_Name (Widget, "button_press_event");
               return True;
            end if;
         end if;

         return False;
      end Button_Press_For_Contextual_Menu;

      ------------------------------
      -- Register_Contextual_Menu --
      ------------------------------

      procedure Register_Contextual_Menu
        (Widget       : access Gtk.Widget.Gtk_Widget_Record'Class;
         User         : User_Data;
         Menu_Create  : Contextual_Menu_Create) is
      begin
         if Widget.Get_Has_Window then
            Add_Events
              (Widget,
               Button_Press_Mask or Button_Release_Mask or Key_Press_Mask);
         end if;

         Contextual_Callback.Connect
           (Widget, Signal_Button_Press_Event,
            Contextual_Callback.To_Marshaller
              (User_Contextual_Menus.Button_Press_For_Contextual_Menu'
                 Unrestricted_Access),
            (Menu_Create  => Menu_Create,
             User         => User));
         Contextual_Callback.Connect
           (Widget, Signal_Key_Press_Event,
            Contextual_Callback.To_Marshaller
              (User_Contextual_Menus.Key_Press_For_Contextual_Menu'
                 Unrestricted_Access),
            (Menu_Create  => Menu_Create,
             User         => User));
      end Register_Contextual_Menu;

   end User_Contextual_Menus;

   -------------------------
   -- Remove_All_Children --
   -------------------------

   procedure Remove_All_Children
     (Container : access Gtk.Container.Gtk_Container_Record'Class;
      Filter    : Filter_Function := null)
   is
      use Widget_List;
      Children : Widget_List.Glist := Get_Children (Container);
      Iter     : Widget_List.Glist := Children;
      N        : Widget_List.Glist;
      W        : Gtk_Widget;
      Child    : Gtk_Widget;
   begin
      while Iter /= Null_List loop
         N := Iter;
         Iter := Next (Iter);
         W := Widget_List.Get_Data (N);

         if Filter = null or else Filter (W) then
            --  Small workaround for a gtk+ bug: a Menu_Item containing an
            --  accel_label would never be destroyed because the label holds a
            --  reference to the menu item, and the latter holds a reference to
            --  the label (see gtk_accel_label_set_accel_widget).

            if W.all in Gtk_Bin_Record'Class then
               Child := Get_Child (Gtk_Bin (W));

               --  Child is null for separators

               if Child /= null then
                  Destroy (Child);
               end if;
            end if;

            Remove (Container, W);
         end if;
      end loop;

      Widget_List.Free (Children);
   end Remove_All_Children;

   ----------------------------
   -- Set_Radio_And_Callback --
   ----------------------------

   procedure Set_Radio_And_Callback
     (Model    : access Gtk.Tree_Store.Gtk_Tree_Store_Record'Class;
      Renderer : access Gtk_Cell_Renderer_Toggle_Record'Class;
      Column   : Glib.Gint) is
   begin
      Set_Radio (Renderer, True);

      Tree_Model_Callback.Object_Connect
        (Renderer, Signal_Toggled,
         Radio_Callback'Access, Slot_Object => Model, User_Data => Column);
   end Set_Radio_And_Callback;

   --------------------
   -- Radio_Callback --
   --------------------

   procedure Radio_Callback
     (Model  : access GObject_Record'Class;
      Params : Glib.Values.GValues;
      Data   : Glib.Gint)
   is
      M           : constant Gtk_Tree_Store := Gtk_Tree_Store (Model);
      Iter, Tmp   : Gtk_Tree_Iter;
      Path_String : constant String := Get_String (Nth (Params, 1));

   begin
      Iter := Get_Iter_From_String (M, Path_String);

      if Iter /= Null_Iter then
         --  Can't click on an already active item, for a radio renderer, since
         --  we want at least one selected item

         if not Get_Boolean (M, Iter, Data) then
            Tmp := Get_Iter_First (M);

            while Tmp /= Null_Iter loop
               Set (M, Tmp, Data, False);
               Next (M, Tmp);
            end loop;

            Set (M, Iter, Data, True);
         end if;
      end if;

   exception
      when E : others => Trace (Me, E);
   end Radio_Callback;

   -------------------------------
   -- Set_Editable_And_Callback --
   -------------------------------

   procedure Set_Editable_And_Callback
     (Model    : access Gtk.Tree_Store.Gtk_Tree_Store_Record'Class;
      Renderer : access Gtk_Cell_Renderer_Text_Record'Class;
      Column   : Glib.Gint) is
   begin
      Tree_Model_Callback.Object_Connect
        (Renderer, Signal_Edited, Edited_Callback'Access,
         Slot_Object => Model, User_Data => Column);
   end Set_Editable_And_Callback;

   ---------------------
   -- Edited_Callback --
   ---------------------

   procedure Edited_Callback
     (Model  : access GObject_Record'Class;
      Params : Glib.Values.GValues;
      Data   : Glib.Gint)
   is
      M           : constant Gtk_Tree_Store := Gtk_Tree_Store (Model);
      Path_String : constant String := Get_String (Nth (Params, 1));
      Text_Value  : constant GValue := Nth (Params, 2);
      Iter        : Gtk_Tree_Iter;
   begin
      Iter := Get_Iter_From_String (M, Path_String);
      Set_Value (M, Iter, Data, Text_Value);

   exception
      when E : others => Trace (Me, E);
   end Edited_Callback;

   -------------
   -- Gtk_New --
   -------------

   procedure Gtk_New
     (Menu_Item : out Full_Path_Menu_Item;
      Label     : String := "";
      Path      : String := "") is
   begin
      Menu_Item := new Full_Path_Menu_Item_Record (Path'Length);
      Initialize (Menu_Item, Label, Path);
   end Gtk_New;

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize
     (Menu_Item : access Full_Path_Menu_Item_Record'Class;
      Label     : String;
      Path      : String) is
   begin
      Initialize
        (Gtk_Menu_Item (Menu_Item),
         Krunch (UTF8_Full_Name (Create (+Label)), 60));
      Menu_Item.Full_Path := Path;
   end Initialize;

   --------------
   -- Get_Path --
   --------------

   function Get_Path
     (Menu_Item : access Full_Path_Menu_Item_Record) return String is
   begin
      return Menu_Item.Full_Path;
   end Get_Path;

   -------------------------
   -- Find_Iter_For_Event --
   -------------------------

   function Find_Iter_For_Event
     (Tree  : access Gtk_Tree_View_Record'Class;
      Event : Gdk_Event_Button) return Gtk_Tree_Iter
   is
      Iter : Gtk_Tree_Iter;
      Col  : Gtk_Tree_View_Column;
   begin
      Coordinates_For_Event (Tree, Event, Iter, Col);
      return Iter;
   end Find_Iter_For_Event;

   -------------------------
   -- Find_Iter_For_Event --
   -------------------------

   function Find_Iter_For_Event
     (Tree  : access Gtk.Tree_View.Gtk_Tree_View_Record'Class;
      Event : Gdk.Event.Gdk_Event) return Gtk.Tree_Model.Gtk_Tree_Iter
   is
      X, Y      : Gdouble;
      Buffer_X  : Gint;
      Buffer_Y  : Gint;
      Row_Found : Boolean;
      Path      : Gtk_Tree_Path;
      N_Model   : Gtk_Tree_Model;
      Iter      : Gtk_Tree_Iter := Null_Iter;
      Column    : Gtk_Tree_View_Column := null;

      procedure On_Selected
        (Model : Gtk_Tree_Model; Path : Gtk_Tree_Path; It : Gtk_Tree_Iter);
      procedure On_Selected
        (Model : Gtk_Tree_Model; Path : Gtk_Tree_Path; It : Gtk_Tree_Iter)
      is
         pragma Unreferenced (Model, Path);
      begin
         if Iter = Null_Iter then
            Iter := It;
         end if;
      end On_Selected;

   begin
      if Event /= null
        and then Get_Event_Type (Event) in Button_Press .. Button_Release
      then
         Get_Coords (Event, X, Y);
         Get_Path_At_Pos
           (Tree,
            Gint (X),
            Gint (Y),
            Path,
            Column,
            Buffer_X,
            Buffer_Y,
            Row_Found);

         if Path = Null_Gtk_Tree_Path then
            return Null_Iter;
         end if;

         Iter := Get_Iter (Get_Model (Tree), Path);
         Path_Free (Path);

      elsif Tree.Get_Selection.Get_Mode = Selection_Multiple then
         Tree.Get_Selection.Selected_Foreach (On_Selected'Unrestricted_Access);

      else
         Tree.Get_Selection.Get_Selected (N_Model, Iter);
      end if;

      return Iter;
   end Find_Iter_For_Event;

   ---------------------------
   -- Coordinates_For_Event --
   ---------------------------

   procedure Coordinates_For_Event
     (Tree   : access Gtk.Tree_View.Gtk_Tree_View_Record'Class;
      Event  : Gdk.Event.Gdk_Event_Button;
      Iter   : out Gtk.Tree_Model.Gtk_Tree_Iter;
      Column : out Gtk.Tree_View_Column.Gtk_Tree_View_Column)
   is
      Buffer_X  : Gint;
      Buffer_Y  : Gint;
      Row_Found : Boolean;
      Path      : Gtk_Tree_Path;
      N_Model   : Gtk_Tree_Model;
   begin
      Column := null;

      if Event.The_Type in Button_Press .. Button_Release then
         Get_Path_At_Pos
           (Tree,
            Gint (Event.X),
            Gint (Event.Y),
            Path,
            Column,
            Buffer_X,
            Buffer_Y,
            Row_Found);

         if Path = Null_Gtk_Tree_Path then
            Iter := Null_Iter;
            return;
         end if;

         Iter := Get_Iter (Get_Model (Tree), Path);
         Path_Free (Path);
      else
         Get_Selected (Get_Selection (Tree), N_Model, Iter);
      end if;
   end Coordinates_For_Event;

   --------------------------
   -- Search_Entity_Bounds --
   --------------------------

   procedure Search_Entity_Bounds
     (Start_Iter : in out Gtk.Text_Iter.Gtk_Text_Iter;
      End_Iter   : out Gtk.Text_Iter.Gtk_Text_Iter;
      Maybe_File : Boolean := False)
   is
      Ignored : Boolean;
   begin
      --  Search forward the end of the entity...
      Copy (Source => Start_Iter, Dest => End_Iter);

      if Maybe_File then
         while not Is_End (End_Iter) loop
            exit when not Is_File_Letter (Gunichar'(Get_Char (End_Iter)));
            Forward_Char (End_Iter, Ignored);
         end loop;

         --  And search backward the begining of the entity...
         while not Is_Start (Start_Iter) loop
            Backward_Char (Start_Iter, Ignored);

            if not Is_File_Letter (Gunichar'(Get_Char (Start_Iter))) then
               Forward_Char (Start_Iter, Ignored);
               exit;
            end if;
         end loop;

      elsif Is_Operator_Letter (Gunichar'(Get_Char (End_Iter))) then
         while not Is_End (End_Iter) loop
            exit when not Is_Operator_Letter (Gunichar'(Get_Char (End_Iter)));
            Forward_Char (End_Iter, Ignored);
         end loop;

         --  And search backward the begining of the entity...
         while not Is_Start (Start_Iter) loop
            Backward_Char (Start_Iter, Ignored);

            if not Is_Operator_Letter (Gunichar'(Get_Char (Start_Iter))) then
               Forward_Char (Start_Iter, Ignored);
               exit;
            end if;
         end loop;

      else
         while not Is_End (End_Iter) loop
            exit when not Is_Entity_Letter (Gunichar'(Get_Char (End_Iter)));
            Forward_Char (End_Iter, Ignored);
         end loop;

         --  And search backward the begining of the entity...
         while not Is_Start (Start_Iter) loop
            Backward_Char (Start_Iter, Ignored);

            if not Is_Entity_Letter (Gunichar'(Get_Char (Start_Iter))) then
               Forward_Char (Start_Iter, Ignored);
               exit;
            end if;
         end loop;
      end if;
   end Search_Entity_Bounds;

   -----------
   -- Image --
   -----------

   function Image
     (Key  : Gdk.Types.Gdk_Key_Type;
      Mods : Gdk.Types.Gdk_Modifier_Type) return String
   is
      Shift   : constant String := "shift-";
      Meta    : constant String := "alt-";
      Control : constant String := "control-";
      Primary : constant String := "primary-";
      Max : constant Natural := Shift'Length + Control'Length + Meta'Length
       + Primary'Length;
      Buffer   : String (1 .. Max);
      Current : Natural := Buffer'First;

   begin
      if Key = 0 then
         return "";
      end if;

      case Key is
         when GDK_Shift_L
           | GDK_Shift_R
           | GDK_Control_L
           | GDK_Control_R
           | GDK_Caps_Lock
           | GDK_Shift_Lock
           | GDK_Meta_L
           | GDK_Meta_R
           | GDK_Alt_L
           | GDK_Alt_R
           =>
            return Special_Key_Binding;

         when others =>
            if (Mods and Shift_Mask) /= 0 then
               Buffer (Current .. Current + Shift'Length - 1) := Shift;
               Current := Current + Shift'Length;
            end if;

            if (Mods and Primary_Mod_Mask) /= 0
               and then Primary_Mod_Mask /= Control_Mask
            then
               Buffer (Current .. Current + Primary'Length - 1) := Primary;
               Current := Current + Primary'Length;
            end if;

            if (Mods and Control_Mask) /= 0 then
               Buffer (Current .. Current + Control'Length - 1) := Control;
               Current := Current + Control'Length;
            end if;

            if (Mods and Mod1_Mask) /= 0 then
               Buffer (Current .. Current + Meta'Length - 1) := Meta;
               Current := Current + Meta'Length;
            end if;

            return
              Buffer (Buffer'First .. Current - 1) & Gdk.Keyval.Name (Key);
      end case;
   end Image;

   -----------
   -- Value --
   -----------

   procedure Value
     (From : String;
      Key  : out Gdk.Types.Gdk_Key_Type;
      Mods : out Gdk.Types.Gdk_Modifier_Type)
   is
      Start : Natural := From'First;
   begin
      Mods := 0;
      for D in From'Range loop
         if From (D) = '-' then
            if From (Start .. D) = "shift-" then
               Mods := Mods or Shift_Mask;
            elsif From (Start .. D) = "control-" then
               Mods := Mods or Control_Mask;
            elsif From (Start .. D) = "alt-" then
               Mods := Mods or Mod1_Mask;
            elsif From (Start .. D) = "cmd-" then
               if Config.Darwin_Target then
                  --  backward compatibility: cmd-<key> are now saved as
                  --  primary-<key> on OSX
                  Mods := Mods or Primary_Mod_Mask; --  command (OSX)
               else
                  Mods := Mods or Mod1_Mask;  --  alt on other systems
               end if;
            elsif From (Start .. D) = "primary-" then
               Mods := Mods or Primary_Mod_Mask;  --  command (OSX) or control
            end if;
            Start := D + 1;
         end if;
      end loop;

      Key := From_Name (From (Start .. From'Last));
   end Value;

   -------------------
   -- Do_Completion --
   -------------------

   procedure Do_Completion
     (View            : access Gtk.Text_View.Gtk_Text_View_Record'Class;
      Completion      : Completion_Handler;
      Prompt_End_Mark : Gtk_Text_Mark;
      Uneditable_Tag  : Gtk_Text_Tag;
      User_Data       : System.Address)
   is
      Buffer : constant Gtk_Text_Buffer := Get_Buffer (View);
      Prompt_Iter, Last_Iter : Gtk_Text_Iter;
   begin
      Get_Iter_At_Mark (Buffer, Prompt_Iter, Prompt_End_Mark);
      Get_End_Iter (Buffer, Last_Iter);

      declare
         use String_List_Utils.String_List;
         Text          : constant String :=
                           Get_Slice (Buffer, Prompt_Iter, Last_Iter);
         Completions   : List :=  Completion (Text, View, User_Data);
         Prefix        : constant String := Longest_Prefix (Completions);
         Node          : List_Node;
         Line          : Gint;
         Offset        : Gint;
         More_Than_One : constant Boolean :=
                           Completions /= Null_List
                           and then Next (First (Completions)) /= Null_Node;
         Success       : Boolean;
         Prev_Begin    : Gtk_Text_Iter;
         Prev_Last     : Gtk_Text_Iter;
         Pos           : Gtk_Text_Iter;
      begin
         if More_Than_One then
            Node := First (Completions);

            --  Get the range copy the current line

            Line := Get_Line (Last_Iter);

            --  Get the offset of the prompt

            Offset := Get_Line_Offset (Prompt_Iter);

            Get_End_Iter (Buffer, Pos);
            Insert (Buffer, Pos, "" & ASCII.LF);

            while Node /= Null_Node loop
               Get_End_Iter (Buffer, Pos);
               Set_Line_Offset (Pos, 0);
               Insert (Buffer, Pos, Data (Node) & ASCII.LF);
               Node := Next (Node);
            end loop;

            Get_Iter_At_Line_Offset (Buffer, Prev_Begin, Line, 0);
            Copy (Prev_Begin, Prev_Last);
            Forward_To_Line_End (Prev_Last, Success);

            Get_End_Iter (Buffer, Pos);
            Insert_Range (Buffer, Pos, Prev_Begin, Prev_Last);

            Get_End_Iter (Buffer, Pos);
            Set_Line_Offset (Pos, 0);

            Get_Iter_At_Line_Offset (Buffer, Prev_Begin, Line, 0);
            Apply_Tag (Buffer, Uneditable_Tag, Prev_Begin, Pos);

            --  Restore the prompt

            Get_End_Iter (Buffer, Prompt_Iter);
            Set_Line_Offset (Prompt_Iter, Offset);

            Move_Mark (Buffer, Prompt_End_Mark, Prompt_Iter);
            Scroll_Mark_Onscreen (View, Prompt_End_Mark);
         end if;

         --  Insert the completion, if any

         if Completions /= Null_List then
            Get_End_Iter (Buffer, Pos);

            if Prefix'Length > Text'Length then
               Insert (Buffer, Pos,
                       Prefix (Prefix'First + Text'Length .. Prefix'Last));
            end if;

            if not More_Than_One then
               Insert (Buffer, Pos, " ");
            end if;

            Free (Completions);
         end if;
      end;
   end Do_Completion;

   --------------------
   -- Save_Accel_Map --
   --------------------

   procedure Save_Accel_Map (Filename : String) is
      File : File_Type;

      procedure Save_Dynamic_Key
        (Accel_Path : String;
         Accel_Key  : Gdk.Types.Gdk_Key_Type;
         Accel_Mods : Gdk.Types.Gdk_Modifier_Type;
         Changed    : Boolean);
      --  Called for each key shortcut the user has defined interactively

      ----------------------
      -- Save_Dynamic_Key --
      ----------------------

      procedure Save_Dynamic_Key
        (Accel_Path : String;
         Accel_Key  : Gdk.Types.Gdk_Key_Type;
         Accel_Mods : Gdk.Types.Gdk_Modifier_Type;
         Changed    : Boolean)
      is
      begin
         if Changed and then Accel_Key /= GDK_VoidSymbol then
            Put_Line (File, "(gtk_accel_path """
                      & Accel_Path
                      & """ """
                      & Accelerator_Name (Accel_Key, Accel_Mods)
                      & """) ");
         end if;
      end Save_Dynamic_Key;

   begin
      Create (File, Out_File, Filename);
      Gtk.Accel_Map.Foreach
        (Save_Dynamic_Key'Unrestricted_Access);
      Close (File);
   end Save_Accel_Map;

   --------------------
   -- Query_Password --
   --------------------

   function Query_User
     (Parent        : Gtk.Window.Gtk_Window;
      Prompt        : String;
      Password_Mode : Boolean;
      Urgent        : Boolean := True;
      Default       : String := "") return String
   is
      Dialog : Gtk_Dialog;
      Button : Gtk_Widget;
      Label  : Gtk_Label;
      GEntry : Gtk_Entry;
   begin
      Gtk_New (Dialog,
               Title  => Prompt,
               Parent => Parent,
               Flags  => Destroy_With_Parent or Modal);

      Gtk_New (Label, Prompt);
      Set_Alignment (Label, 0.0, 0.5);
      Pack_Start (Get_Content_Area (Dialog), Label, Expand => False);

      Gtk_New (GEntry);
      Pack_Start (Get_Content_Area (Dialog), GEntry, Expand => False);
      Set_Activates_Default (GEntry, True);
      Set_Text (GEntry, Default);

      if Password_Mode then
         Set_Visibility (GEntry, Visible => False);
      end if;

      Button := Add_Button (Dialog, Stock_Ok, Gtk_Response_OK);
      Grab_Default (Button);
      Button := Add_Button (Dialog, Stock_Cancel, Gtk_Response_Cancel);

      Show_All (Dialog);
      --  Make sure the dialog is presented to the user
      Present (Dialog);

      if Urgent then
         Set_Urgency_Hint (Dialog, True);
      end if;

      Set_Keep_Above (Dialog, True);

      if Run (Dialog) = Gtk_Response_OK then
         declare
            Pass : constant String := Get_Text (GEntry);
         begin
            Destroy (Dialog);
            return Pass;
         end;
      else
         Destroy (Dialog);
         return "";
      end if;
   end Query_User;

   ----------------------------
   -- Find_Menu_Item_By_Name --
   ----------------------------

   procedure Find_Menu_Item_By_Name
     (Menu_Bar  : Gtk_Menu_Bar;
      Menu      : Gtk_Menu;
      Name      : String;
      Menu_Item : out Gtk_Menu_Item;
      Index     : out Gint)
   is
      use type Widget_List.Glist;
      Children, Tmp   : Widget_List.Glist;
      Label         : Gtk_Label;
      Box           : Gtk_Box;
      New_Name      : constant String :=
        Unescape_Underscore (Strip_Single_Underscores (Name));

   begin
      Menu_Item := null;

      if Name = "" then
         Index := -1;
         return;
      end if;

      if Menu /= null then
         Children := Get_Children (Menu);
      elsif Menu_Bar /= null then
         Children := Get_Children (Menu_Bar);
      else
         Children := Widget_List.Null_List;
      end if;

      Index := 0;
      Tmp := Children;

      while Tmp /= Widget_List.Null_List loop
         Menu_Item := Gtk_Menu_Item (Widget_List.Get_Data (Tmp));

         if Get_Child (Menu_Item) /= null
           and then Get_Child (Menu_Item).all in Gtk_Label_Record'Class
         then
            Label := Gtk_Label (Get_Child (Menu_Item));
            exit when Equal
              (Get_Text (Label), New_Name, Case_Sensitive => False);

         elsif Get_Child (Menu_Item) /= null
           and then Get_Child (Menu_Item).all in Gtk_Box_Record'Class
         then
            --  Support for radio menu items created by Gtkada.MDI
            Box := Gtk_Box (Get_Child (Menu_Item));
            if Get_Child (Box, 0) /= null
              and then Get_Child (Box, 0).all in Gtk_Label_Record'Class
            then
               Label := Gtk_Label (Get_Child (Box, 0));
               exit when Equal
                 (Get_Text (Label), New_Name, Case_Sensitive => False);

            elsif Get_Child (Box, 1) /= null
              and then Get_Child (Box, 1).all in Gtk_Label_Record'Class
            then
               Label := Gtk_Label (Get_Child (Box, 1));
               exit when Equal
                 (Get_Text (Label), New_Name, Case_Sensitive => False);
            end if;
         end if;

         Index := Index + 1;
         Tmp := Widget_List.Next (Tmp);
         Menu_Item := null;
      end loop;

      Widget_List.Free (Children);

      if Menu_Item = null then
         Index := -1;
      end if;
   end Find_Menu_Item_By_Name;

   ----------------------
   -- Create_Menu_Path --
   ----------------------

   function Create_Menu_Path
     (Item : not null access Gtk.Menu_Item.Gtk_Menu_Item_Record'Class)
      return String
   is
      Path   : constant String := Item.Get_Accel_Path;
      P      : Integer := Path'First;
      Result : String (Path'Range);
      Index  : Integer := Result'First;
   begin
      if Starts_With (Path, "<gps>") then
         P := Path'First + 5;
      end if;

      while P <= Path'Last loop
         if Path (P) /= '_' then
            Result (Index) := Path (P);
            Index := Index + 1;
         end if;
         P := P + 1;
      end loop;

      return Result (Result'First .. Index - 1);
   end Create_Menu_Path;

   ----------------------
   -- Create_Menu_Path --
   ----------------------

   function Create_Menu_Path (Parent, Menu : String) return String
   is
      function Cleanup (Path : String) return String;
      --  Remove duplicate // in Path

      function Cleanup (Path : String) return String is
         Output : String (Path'Range);
         Index  : Natural := Output'First;
      begin
         for P in Path'Range loop
            if Path (P) /= '/'
              or else P + 1 > Path'Last
              or else Path (P + 1) /= '/'
            then
               Output (Index) := Path (P);
               Index          := Index + 1;
            end if;
         end loop;
         return Output (Output'First .. Index - 1);
      end Cleanup;

   begin
      if Parent = "" then
         return Cleanup (Menu);
      elsif Parent (Parent'Last) = '/' then
         return Cleanup (Parent & Menu);
      else
         return Cleanup (Parent & '/' & Menu);
      end if;
   end Create_Menu_Path;

   ----------------------
   -- Escape_Menu_Name --
   ----------------------

   function Escape_Menu_Name (Name : String) return String is
      R : Unbounded_String;
   begin
      for N in Name'Range loop
         if Name (N) = '/'
           or else Name (N) = '\'
         then
            Append (R, '\' & Name (N));
         else
            Append (R, Name (N));
         end if;
      end loop;
      return To_String (R);
   end Escape_Menu_Name;

   ------------------------
   -- Unescape_Menu_Name --
   ------------------------

   function Unescape_Menu_Name (Name : String) return String is
      R : Unbounded_String;
      Index : Natural := Name'First;
   begin
      while Index <= Name'Last loop
         if Name (Index) = '\' and then Index < Name'Last then
            Index := Index + 1;
         end if;
         Append (R, Name (Index));
         Index := Index + 1;
      end loop;
      return To_String (R);
   end Unescape_Menu_Name;

   -----------------------
   -- Escape_Underscore --
   -----------------------

   function Escape_Underscore (Name : String) return String is
      R : Unbounded_String;
   begin
      for N in Name'Range loop
         if Name (N) = '_' then
            Append (R, "__");
         else
            Append (R, Name (N));
         end if;
      end loop;
      return To_String (R);
   end Escape_Underscore;

   -------------------------
   -- Unescape_Underscore --
   -------------------------

   function Unescape_Underscore (Name : String) return String is
      Result : String (Name'Range);
      Last   : Integer := Result'First;
   begin
      for N in Name'Range loop
         if Name (N) = '_'
           and then N > Name'First
           and then Name (N - 1) = '_'
         then
            null;
         else
            Result (Last) := Name (N);
            Last := Last + 1;
         end if;
      end loop;
      return Result (Result'First .. Last - 1);
   end Unescape_Underscore;

   ----------------------
   -- Parent_Menu_Name --
   ----------------------

   function Parent_Menu_Name (Name : String) return String is
   begin
      for N in reverse Name'Range loop
         if Name (N) = '/' and then
           (N = Name'First
            or else (Name (N - 1) /= '\' and then Name (N - 1) /= '<'))
         then
            return Name (Name'First .. N);
         end if;
      end loop;
      return "/";
   end Parent_Menu_Name;

   --------------------
   -- Base_Menu_Name --
   --------------------

   function Base_Menu_Name (Path : String) return String is
   begin
      for N in reverse Path'Range loop
         if Path (N) = '/'
           and then N /= Path'First
           and then Path (N - 1) /= '\'
           and then Path (N - 1) /= '<'   --  ignore pango markup
         then
            return Unescape_Menu_Name (Path (N + 1 .. Path'Last));
         end if;
      end loop;
      return Path;
   end Base_Menu_Name;

   ------------------------------
   -- Find_Or_Create_Menu_Tree --
   ------------------------------

   function Find_Or_Create_Menu_Tree
     (Menu_Bar      : Gtk_Menu_Bar;
      Menu          : Gtk_Menu;
      Path          : String;
      Accelerators  : Gtk.Accel_Group.Gtk_Accel_Group;
      Allow_Create  : Boolean := True;
      Ref_Item      : String  := "";
      Add_Before    : Boolean := True;
      New_Item      : access Gtk.Menu_Item.Gtk_Menu_Item_Record'Class := null)
      return Gtk_Menu_Item
   is
      procedure Unchecked_Free is new Ada.Unchecked_Deallocation
        (Gtk_Menu_Item_Record'Class, Gtk_Menu_Item);
      First     : Natural := Path'First;
      Last      : Natural;
      Parent    : Gtk_Menu := Menu;
      Menu_Item : Gtk_Menu_Item;
      Pred      : Gtk_Menu_Item;
      M         : Gtk_Menu;
      Index     : Gint;
   begin
      if Path /= "" and then Path (First) = '/' then
         First := First + 1;
      end if;

      --  Find the existing parents

      while First <= Path'Last loop
         Last := First + 1;
         Skip_To_Char (Path, Last, '/');

         if Last > First and then Last < Path'Last
           and then Path (Last - 1) = '\'
         then
            Last := Last + 1;
            Skip_To_Char (Path, Last, '/');
         end if;

         Find_Menu_Item_By_Name
           (Menu_Bar, Parent,
            Unescape_Menu_Name (Path (First .. Last - 1)),
            Menu_Item, Index);

         exit when Menu_Item = null;

         --  Have we found the item ?
         First  := Last + 1;
         exit when Last >= Path'Last;

         if Get_Submenu (Menu_Item) = null then
            return null;
         end if;

         Parent := Gtk_Menu (Get_Submenu (Menu_Item));
      end loop;

      --  Create the missing parents

      if Allow_Create then
         while First <= Path'Last loop
            Last := First + 1;
            Skip_To_Char (Path, Last, '/');

            if Last > First and then Last < Path'Last
              and then Path (Last - 1) = '\'
            then
               Last := Last + 1;
               Skip_To_Char (Path, Last, '/');
            end if;

            if Last > Path'Last and then New_Item /= null then
               Menu_Item := Gtk_Menu_Item (New_Item);
            else
               Menu_Item := new Gtk_Menu_Item_Record;
            end if;

            Initialize_With_Mnemonic (Menu_Item, Path (First .. Last - 1));

            --  Should we create a submenu ?
            if Last <= Path'Last then
               Gtk_New (M);
               Set_Submenu (Menu_Item, M);
               Set_Accel_Group (M, Accelerators);
            end if;

            Find_Menu_Item_By_Name
              (Menu_Bar, Parent, Ref_Item, Pred, Index);

            Add_Menu (Parent, Menu_Bar, Menu_Item, Index, Add_Before);
            Show_All (Menu_Item);
            Parent := M;

            First := Last + 1;
         end loop;

      elsif First <= Path'Last then
         --  No such item
         Menu_Item := null;
      end if;

      if Menu_Item = null then
         Menu_Item := Gtk_Menu_Item (New_Item);
         Unchecked_Free (Menu_Item);
      end if;

      return Menu_Item;
   end Find_Or_Create_Menu_Tree;

   --------------
   -- Add_Menu --
   --------------

   procedure Add_Menu
     (Parent     : Gtk_Menu;
      Menu_Bar   : Gtk_Menu_Bar := null;
      Item       : access Gtk_Menu_Item_Record'Class;
      Index      : Gint := -1;
      Add_Before : Boolean := True)
   is
      P : Gtk_Menu_Shell := Gtk_Menu_Shell (Parent);
   begin
      --  Insertion in the menu bar
      if Parent = null then
         P := Gtk_Menu_Shell (Menu_Bar);
      end if;

      if Index = -1 then
         Append (P, Item);
      elsif Add_Before then
         Insert (P, Item, Index);
      else
         Insert (P, Item, Index + 1);
      end if;
   end Add_Menu;

   ---------------
   -- Find_Node --
   ---------------

   function Find_Node
     (Model  : Gtk_Tree_Store;
      Name   : String;
      Column : Gint) return Gtk_Tree_Iter
   is
      Parent : Gtk_Tree_Iter := Get_Iter_First (Model);
   begin
      while Parent /= Null_Iter loop
         if Get_String (Model, Parent, Column) = Name then
            return Parent;
         end if;
         Next (Model, Parent);
      end loop;

      return Null_Iter;
   end Find_Node;

   -----------------------
   -- Create_Blue_Label --
   -----------------------

   procedure Create_Blue_Label
     (Label : out Gtk.Label.Gtk_Label;
      Event : out Gtk.Event_Box.Gtk_Event_Box)
   is
      Color   : Gdk_RGBA;
      Success : Boolean;
   begin
      Gtk_New (Event);
      Parse (Color, "#0e79bd", Success);
      Event.Override_Background_Color (Gtk_State_Flag_Normal, Color);

      Gtk_New (Label, "");
      Set_Alignment (Label, 0.1, 0.5);
      Add (Event, Label);
   end Create_Blue_Label;

   ----------------------
   -- Create_Tree_View --
   ----------------------

   function Create_Tree_View
     (Column_Types       : Glib.GType_Array;
      Column_Names       : GNAT.Strings.String_List;
      Show_Column_Titles : Boolean := True;
      Selection_Mode     : Gtk.Enums.Gtk_Selection_Mode :=
        Gtk.Enums.Selection_Single;
      Sortable_Columns   : Boolean := True;
      Initial_Sort_On    : Integer := -1;
      Hide_Expander      : Boolean := False;
      Merge_Icon_Columns : Boolean := True;
      Editable_Columns   : Gint_Array := (1 .. 0 => -1);
      Editable_Callback  : Editable_Callback_Array := (1 .. 0 => null))
      return Gtk.Tree_View.Gtk_Tree_View
   is
      View              : Gtk_Tree_View;
      Col               : Gtk_Tree_View_Column;
      Col_Number        : Gint;
      Model             : Gtk_Tree_Store;
      Text_Render       : Gtk_Cell_Renderer_Text;
      Toggle_Render     : Gtk_Cell_Renderer_Toggle;
      Pixbuf_Render     : Gtk_Cell_Renderer_Pixbuf;
      Previous_Was_Icon : Boolean := False;
      Is_Icon           : Boolean;
      ColNum            : Guint;
      pragma Unreferenced (Col_Number);
   begin
      Gtk_New (Model, Column_Types);
      Gtk_New (View, Model);
      Unref (Model);
      Set_Mode (Get_Selection (View), Selection_Mode);
      Set_Headers_Visible (View, Show_Column_Titles);
      Set_Enable_Search (View, True);

      if Hide_Expander then
         --  Create an explicit columns for the expander
         Gtk_New (Col);
         Col_Number := Append_Column (View, Col);
         Set_Expander_Column (View, Col);
         Set_Visible (Col, False);
         Col := null;
      end if;

      for N in 0
        .. Integer'Min (Column_Names'Length, Column_Types'Length) - 1
      loop
         ColNum := Column_Types'First + Guint (N);
         Is_Icon := Column_Types (ColNum) = Gdk.Pixbuf.Get_Type;

         --  Reuse existing column for icons
         if not Merge_Icon_Columns
           or else (not Previous_Was_Icon
                    and then (Col = null or else not Is_Icon))
         then
            Gtk_New         (Col);
            Set_Resizable   (Col, True);
            Set_Reorderable (Col, True);

            Col_Number := Append_Column (View, Col);
            if Column_Names (Column_Names'First + N) /= null then
               Set_Title (Col, Column_Names (Column_Names'First + N).all);
            end if;
         end if;

         if not Is_Icon and then Sortable_Columns then
            Set_Sort_Column_Id (Col, Gint (N));
            Set_Clickable (Col, True);
            if Initial_Sort_On = N + Column_Names'First then
               Clicked (Col);
            end if;
         end if;

         Previous_Was_Icon := Is_Icon;

         if Column_Types (ColNum) = GType_Boolean then
            Gtk_New (Toggle_Render);
            Set_Radio (Toggle_Render, False);
            Pack_Start (Col, Toggle_Render, False);
            Add_Attribute (Col, Toggle_Render, "active", Gint (N));

            Tree_Column_Callback.Connect
              (Toggle_Render, Signal_Toggled,
               Toggle_Callback'Access,
               User_Data => (+Model, Gint (N)));

            if Integer (ColNum) in Editable_Columns'Range
              and then Editable_Columns (Integer (ColNum)) >= 0
            then
               Add_Attribute
                 (Col, Toggle_Render, "activatable",
                  Editable_Columns (Integer (ColNum)));

               if Integer (ColNum) in Editable_Callback'Range
                 and then Editable_Callback (Integer (ColNum)) /= null
               then
                  Widget_Callback.Object_Connect
                    (Toggle_Render, Signal_Toggled,
                     Widget_Callback.Handler
                       (Editable_Callback (Integer (ColNum))),
                     Slot_Object => View, After => True);
               end if;
            end if;

         elsif Column_Types (ColNum) = GType_String
           or else Column_Types (ColNum) = GType_Int
         then
            Gtk_New (Text_Render);
            Pack_Start (Col, Text_Render, False);
            Add_Attribute (Col, Text_Render, "text", Gint (N));

            if Integer (ColNum) in Editable_Columns'Range
              and then Editable_Columns (Integer (ColNum)) >= 0
            then
               Add_Attribute
                 (Col, Text_Render, "editable",
                  Editable_Columns (Integer (ColNum)));

               --  First connect the user callback, before validating the
               --  change in the second callback: validating the change could
               --  force the tree view to resort itself, thus making the path
               --  we are giving the user callback invalid.
               if Integer (ColNum) in Editable_Callback'Range
                 and then Editable_Callback (Integer (ColNum)) /= null
               then
                  Widget_Callback.Object_Connect
                    (Text_Render, Signal_Edited,
                     Widget_Callback.Handler
                       (Editable_Callback (Integer (ColNum))),
                     Slot_Object => View);
               end if;

               Tree_Model_Callback.Object_Connect
                 (Text_Render, Signal_Edited, Edited_Callback'Access,
                  Slot_Object => Model, User_Data => Gint (N));
            end if;

         elsif Is_Icon then
            if Pixbuf_Render = null then
               Gtk_New (Pixbuf_Render);
            end if;
            Pack_Start (Col, Pixbuf_Render, False);
            Add_Attribute (Col, Pixbuf_Render, "pixbuf", Gint (N));

         else
            raise Program_Error;
         end if;
      end loop;

      return View;
   end Create_Tree_View;

   ---------------------
   -- Toggle_Callback --
   ---------------------

   procedure Toggle_Callback
     (Render : access GObject_Record'Class;
      Params : Glib.Values.GValues;
      Data   : Model_Column)
   is
      R           : constant Gtk_Cell_Renderer := Gtk_Cell_Renderer (Render);
      Path_String : constant String := Get_String (Nth (Params, 1));
      Iter        : Gtk_Tree_Iter;
      Activatable : Boolean;
      M           : Gtk_Tree_Store;
   begin
      Iter := Get_Iter_From_String (Data.Model, Path_String);

      if Iter /= Null_Iter then
         --  The activatable property only prevents us from activating the
         --  toggle, not from deactivating it
         Activatable :=
           Get_Property (R, Property_Boolean (Glib.Build ("activatable")));

         if Activatable then
            M := -Data.Model;
            Set (M, Iter, Data.Column,
                 not Get_Boolean (M, Iter, Data.Column));
         end if;
      end if;
   end Toggle_Callback;

   ----------------
   -- Expand_Row --
   ----------------

   procedure Expand_Row
     (Tree  : access Gtk.Tree_View.Gtk_Tree_View_Record'Class;
      Iter  : Gtk.Tree_Model.Gtk_Tree_Iter)
   is
      Path : Gtk_Tree_Path;
      Tmp  : Boolean;
      pragma Unreferenced (Tmp);
   begin
      Path := Get_Path (Get_Model (Tree), Iter);
      Tmp := Expand_Row (Tree, Path, Open_All => False);
      Path_Free (Path);
   end Expand_Row;

   -------------------
   -- Get_Selection --
   -------------------

   function Get_Selection
     (Tree : access Gtk.Tree_View.Gtk_Tree_View_Record'Class) return String
   is
      Sel    : Gtk_Tree_Selection;
      Model  : Gtk_Tree_Model;
      Iter   : Gtk_Tree_Iter;
      Nc     : Gint;
      Result : Unbounded_String;
   begin
      Sel := Gtk.Tree_View.Get_Selection (Tree);

      Get_Selected (Sel, Model, Iter);

      if Iter = Null_Iter then
         return "";

      else
         Nc := Get_N_Columns (Model);

         for K in 0 .. Nc - 1 loop
            if Get_Column_Type (Model, K) = GType_String then
               --  We only copy the string columns
               declare
                  V : constant String :=
                        Gtk.Tree_Model.Get_String (Model, Iter, K);
               begin
                  if V /= "" then
                     if Result /= Null_Unbounded_String then
                        Append (Result, ' ');
                     end if;
                     Append (Result, V);
                  end if;
               end;
            end if;
         end loop;

         return To_String (Result);
      end if;
   end Get_Selection;

   ----------------------------------
   -- Gtk_New_From_Stock_And_Label --
   ----------------------------------

   procedure Gtk_New_From_Stock_And_Label
     (Button   : out Gtk_Button;
      Stock_Id : String;
      Label    : String)
   is
      Box : Gtk_Box;
      Lab : Gtk_Label;
      Img : Gtk_Image;
      Align : Gtk_Alignment;
   begin
      Gtk_New (Button);

      Gtk_New (Align, 0.5, 0.5, 0.0, 0.0);
      Add (Button, Align);

      Gtk_New_Hbox (Box, Homogeneous => False);
      Add (Align, Box);

      Gtk_New (Img, Stock_Id => Stock_Id, Size => Icon_Size_Button);
      Pack_Start (Box, Img, Expand => False);

      Gtk_New (Lab, Label);
      Pack_Start (Box, Lab, Expand => False, Fill => True);
   end Gtk_New_From_Stock_And_Label;

   ------------
   -- Format --
   ------------

   function Format (S : String) return String is
      D : constant String := Format_Pathname (S, UNIX);
   begin
      if S = "" then
         return "";
      end if;

      if D (D'Last) = '/' then
         return D;
      else
         return D & '/';
      end if;
   end Format;

   ------------
   -- Darken --
   ------------

   function Darken (Color : Gdk.RGBA.Gdk_RGBA) return Gdk.RGBA.Gdk_RGBA is
   begin
      return
        (Red   => Color.Red * 0.9,
         Green => Color.Green * 0.9,
         Blue  => Color.Blue * 0.9,
         Alpha => Color.Alpha);
   end Darken;

   -------------
   -- Lighten --
   -------------

   function Lighten (Color : Gdk.RGBA.Gdk_RGBA) return Gdk.RGBA.Gdk_RGBA is
      Percent : constant := 0.1;
      White   : constant := 0.1;
   begin
      --  Very basic algorithm. Since we also want to change blacks, we can't
      --  simply multiply RGB components, so we just move part of the way to
      --  white:    R' = R + (White - R) * 10% = 90% * R + 10% * White

      return
        (Red   => Color.Red * (1.0 - Percent) + White,
         Green => Color.Green * (1.0 - Percent) + White,
         Blue  => Color.Blue * (1.0 - Percent) + White,
         Alpha => Color.Alpha);
   end Lighten;

   -----------------------
   -- Darken_Or_Lighten --
   -----------------------

   function Darken_Or_Lighten
     (Color : Gdk.RGBA.Gdk_RGBA) return Gdk.RGBA.Gdk_RGBA
   is
      --  Compute luminosity as in photoshop (as per wikipedia)
      Luminosity : constant Gdouble :=
        0.299 * Color.Red
        + 0.587 * Color.Green
        + 0.114 * Color.Blue;

      Gray_Luminosity : constant Gdouble :=
        0.299 * 0.5
        + 0.587 * 0.5
        + 0.114 * 0.5;
   begin
      if Luminosity > Gray_Luminosity then
         return Darken (Color);
      else
         return Lighten (Color);
      end if;
   end Darken_Or_Lighten;

   ------------------------
   -- Remove_Child_Nodes --
   ------------------------

   procedure Remove_Child_Nodes
     (Model  : access Gtk.Tree_Store.Gtk_Tree_Store_Record'Class;
      Parent : Gtk_Tree_Iter)
   is
      Iter : Gtk_Tree_Iter;
   begin
      loop
         Iter := Model.Nth_Child (Parent, 0);
         exit when Iter = Null_Iter;
         Model.Remove (Iter);
      end loop;
   end Remove_Child_Nodes;

   ---------------------
   -- Idle_Grab_Focus --
   ---------------------

   function Idle_Grab_Focus (Widget : Gtk_Widget) return Boolean is
   begin
      Grab_Focus (Widget);
      return False;
   end Idle_Grab_Focus;

   ---------------------
   -- Get_MDI_Windows --
   ---------------------

   function Get_MDI_Windows
     (MDI : not null access Gtkada.MDI.MDI_Window_Record'Class)
      return Windows_Sets.Set
   is
      use Gtkada.MDI;
      Iter  : Child_Iterator := First_Child (MDI);
      Child : MDI_Child;
      W     : Gtk_Widget;
   begin
      return S : Windows_Sets.Set do
         while Get (Iter) /= null loop
            Child := Get (Iter);
            W := (if Child.Is_Floating then Child.Get_Widget.Get_Toplevel
                  else Child.Get_Toplevel);

            if W.all in Gtk_Window_Record'Class then
               S.Include (Gtk_Window (W));
            end if;

            Next (Iter);
         end loop;
      end return;
   end Get_MDI_Windows;

   -------------------------
   -- Grab_Toplevel_Focus --
   -------------------------

   procedure Grab_Toplevel_Focus
     (MDI    : not null access Gtkada.MDI.MDI_Window_Record'Class;
      Widget : not null access Gtk.Widget.Gtk_Widget_Record'Class)
   is
      Win : Gtk_Widget;
      Id : Glib.Main.G_Source_Id;
      pragma Unreferenced (Id);
      GPS_Has_Focus : constant Boolean :=
        (for some W of Get_MDI_Windows (MDI) => W.Has_Toplevel_Focus);
   begin

      --  Don't do anything if GPS doesn't have the focus at a Window Manager
      --  level - that is, if none of it's toplevel windows has toplevel focus

      if not GPS_Has_Focus then
         return;
      end if;

      MDI.Set_Focus_Child (Widget);

      Win := Get_Toplevel (Widget);

      --  Do not Present a window if it hasn't been realized yet:
      --  this would give the window its default size as defined in
      --  GPS.Main_Window rather than the one coming from the desktop
      --  saved in the MDI.

      if Win /= null
        and then Win.Get_Realized
        and then Win.all in Gtk_Window_Record'Class
      then
         Gtk_Window (Win).Present;
      else
         Win := MDI.Get_Toplevel;
         if Win /= null
           and then Win.Get_Realized
           and then Win.all in Gtk_Window_Record'Class
         then
            Gtk_Window (Win).Present;
         end if;
      end if;

      if not Widget.Has_Focus then
         Widget.Grab_Focus;
      end if;
   end Grab_Toplevel_Focus;

   --------------
   -- Move_Row --
   --------------

   procedure Move_Row
     (View    : not null access Gtk.Tree_View.Gtk_Tree_View_Record'Class;
      Iter    : in out Gtk_Tree_Iter;
      Forward : Boolean := True)
   is
      Model : constant Gtk_Tree_Model := Get_Model (View);
      C, P  : Gtk_Tree_Iter;
      Path  : Gtk_Tree_Path;
      Dummy : Boolean;
      pragma Unreferenced (Dummy);
   begin
      if Forward then
         C := Children (Model, Iter);
         if C /= Null_Iter then
            Path := Get_Path (Model, C);
            Dummy := View.Expand_Row (Path, Open_All => False);
            Iter := C;
            return;
         end if;

         C := Iter;
         Next (Model, C);
         if C /= Null_Iter then
            Iter := C;
            return;
         end if;

         C := Parent (Model, Iter);
         Next (Model, C);
         Iter := C;
      else
         P := Iter;
         Previous (Model, P);
         if P /= Null_Iter then
            if Has_Child (Model, P) then
               Iter := Nth_Child (Model, P, N_Children (Model, P));
               Path := Get_Path (Model, P);
               Dummy := View.Expand_Row (Path, Open_All => False);
               return;
            end if;

            Iter := P;
            return;
         end if;

         Iter := Parent (Model, Iter);
      end if;
   end Move_Row;

end GUI_Utils;

-----------------------------------------------------------------------
--                               G P S                               --
--                                                                   --
--                    Copyright (C) 2002 - 2004                      --
--                            ACT-Europe                             --
--                                                                   --
-- GPS is free  software;  you can redistribute it and/or modify  it --
-- under the terms of the GNU General Public License as published by --
-- the Free Software Foundation; either version 2 of the License, or --
-- (at your option) any later version.                               --
--                                                                   --
-- This program is  distributed in the hope that it will be  useful, --
-- but  WITHOUT ANY WARRANTY;  without even the  implied warranty of --
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU --
-- General Public License for more details. You should have received --
-- a copy of the GNU General Public License along with this program; --
-- if not,  write to the  Free Software Foundation, Inc.,  59 Temple --
-- Place - Suite 330, Boston, MA 02111-1307, USA.                    --
-----------------------------------------------------------------------

--  This package provides facilities for customizing menus,
--  keyboard shortcuts, and so on, in GPS.

--  Here is the format for the custom menus file :
--
--  <Custom>
--
--    <Submenu>
--      <Title>Title for toplevel menu</Title>
--
--      <Menuitem>
--        <Title>title 1</Title>
--        <Shortcut>keyboard shortcut</Shortcut>
--        <Action>command 1</Action>
--        <Action>command 2</Action>
--      </Menuitem>
--
--      <Submenu>
--        <Title>title for submenu</Title>
--        <Menuitem>
--          <Title> (etc..)
--        </Menuitem>
--
--        <Submenu>
--               (...)
--        </Submenu>
--      </Submenu>
--    </Submenu>
--
--    <Submenu>
--      <Title>Title for toplevel menu number 2</Title>
--             (...)
--    </Submenu>
--
--    <Button>
--      <Title>Button label/tooltip</Title>
--      <Pixmap>location of pixmap (xpm) file</Pixmap>
--      <Action>command 1</Action>
--    </Button>
--
--  </Custom>
--
--  Titles like "_File", "Open from _Project", ... can now be used,
--  The underscores identify the accelerator keys.
--
--  You can add items or submenus to existing menus :
--
--   This adds an item named "Robert" to the "Edit" menu.
--      <Submenu>
--         <Title>Edit</Title>
--         <Menuitem>
--           <Title>Robert</Title>
--         </Menuitem>
--      </Submenu>
--
--  This adds a submenu named "Olga" to the "Edit" menu.
--  <Submenu>
--     <Title>Edit/Olga</Title>
--     <Menuitem>
--       <Title>title 1</Title>
--     </Menuitem>
--  </Submenu>
--
--  Adding an item with an empty title or a null title will insert
--  a menu separator.
--
--  Here is a non-exhaustive list of possible enhancements here
--    -> facilities for creating toolbar buttons
--    -> be able to position the custom menus relatively to
--       other menus
--    -> add icons to the menus (using stock icons or image files)
--    -> make the file syntax a little more flexible
--       (right now it's very case-sensitive, and so on)
--    -> Use GPS commands as well as shell commands
--    -> give access to the contextual menu factories
--    -> implement a GUI to create those menus graphically

with Glide_Kernel;
with GNAT.OS_Lib;               use GNAT.OS_Lib;
with GNAT.Expect;
with GNAT.Regpat;
with Glide_Kernel.Actions;      use Glide_Kernel.Actions;
with Glide_Kernel;              use Glide_Kernel;
with Gtk.Combo;                 use Gtk.Combo;
with HTables;
with Generic_List;

with Ada.Unchecked_Deallocation;

package Custom_Module is

   ---------------------------------------------
   -- Definitions for the interface to expect --
   ---------------------------------------------

   type Pattern_Matcher_Access is access GNAT.Regpat.Pattern_Matcher;
   procedure Unchecked_Free is new Ada.Unchecked_Deallocation
     (GNAT.Regpat.Pattern_Matcher, Pattern_Matcher_Access);

   type Expect_Filter is record
      Pattern : Pattern_Matcher_Access;
      Action  : Action_Record_Access;
   end record;

   procedure Free (X : in out Expect_Filter);
   --  Free memory associated to X.

   package Expect_Filter_List is new Generic_List (Expect_Filter);

   type Custom_Action_Record is record
      Command_Id : Integer;
      Pattern    : Pattern_Matcher_Access;
      Command    : Argument_List_Access;
      On_Match   : Action_Record_Access;
      On_Exit    : Action_Record_Access;
      Fd         : GNAT.Expect.Process_Descriptor_Access;

      Processed_Output : String_Access;
      Unmatched_Output : String_Access;

      Filters    : Expect_Filter_List.List;
   end record;

   type Custom_Action_Access is access all Custom_Action_Record;
   procedure Unchecked_Free is new Ada.Unchecked_Deallocation
     (Custom_Action_Record, Custom_Action_Access);

   type Header_Num is range 1 .. 1_000;

   procedure Free (X : in out Custom_Action_Access);
   procedure Free (X : in out Custom_Action_Record);
   --  Free memory associated to X.

   No_Custom_Action : aliased Custom_Action_Record :=
     (0, null, null, null, null, null, null, null,
      Expect_Filter_List.Null_List);

   function Hash (K : Integer) return Header_Num;

   package Processes_Hash is new HTables.Simple_HTable
     (Header_Num, Custom_Action_Access, Free,
      No_Custom_Action'Access, Integer, Hash, "=");

   ------------------------------------------
   -- Definitions for custom combo entries --
   ------------------------------------------

   type Entry_Action_Record is record
      Label   : String_Access;
      --  This is an allocated string identifying the action.
      --  This can never be null.

      Command : Action_Record_Access;
      --  This should not be allocated/deallocated.
   end record;

   procedure Free (X : in out Entry_Action_Record);
   --  Free memory associated to X.

   package Entry_List is new Generic_List (Entry_Action_Record);

   type GPS_Combo_Record is record
      Label            : String_Access;
      Combo            : Gtk_Combo;
      On_Change_Action : Action_Record_Access;
      Entries          : Entry_List.List;
   end record;

   type GPS_Combo_Access is access GPS_Combo_Record;
   procedure Unchecked_Free is new Ada.Unchecked_Deallocation
     (GPS_Combo_Record, GPS_Combo_Access);

   procedure Free (X : in out GPS_Combo_Access);
   --  Free memory associated to X.

   package Combo_List is new Generic_List (GPS_Combo_Access);
   --  ??? Should this be a HTable ?

   --------------------------------------
   -- Definitions for contextual menus --
   --------------------------------------

   type Contextual_Menu_Record;
   type Contextual_Menu_Access is access all Contextual_Menu_Record;
   type Contextual_Menu_Record is record
      Title  : String_Access;
      Action : Action_Record_Access;
      Next   : Contextual_Menu_Access;
   end record;

   ----------------------
   -- Custom_Module_ID --
   ----------------------

   type Custom_Module_ID_Record is new Module_ID_Record with record
      Kernel     : Kernel_Handle;

      Contextual : Contextual_Menu_Access;

      Processes    : Processes_Hash.HTable;
      Available_Id : Integer := 1;

      Combos       : Combo_List.List;
   end record;
   type Custom_Module_ID_Access is access all Custom_Module_ID_Record'Class;

   Custom_Module_ID   : Custom_Module_ID_Access;

   procedure Register_Module
     (Kernel : access Glide_Kernel.Kernel_Handle_Record'Class);
   --  Register the module into the list

end Custom_Module;

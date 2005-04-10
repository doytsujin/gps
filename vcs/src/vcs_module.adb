-----------------------------------------------------------------------
--                              G P S                                --
--                                                                   --
--                     Copyright (C) 2001-2005                       --
--                             AdaCore                               --
--                                                                   --
-- GPS is free  software; you can  redistribute it and/or modify  it --
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

with Glib;                      use Glib;
with Glib.Xml_Int;              use Glib.Xml_Int;
with Glib.Object;               use Glib.Object;
with Gtk.Menu;                  use Gtk.Menu;
with Gtk.Menu_Item;             use Gtk.Menu_Item;
with Gtk.Widget;                use Gtk.Widget;
with Gtkada.MDI;                use Gtkada.MDI;

with GPS.Kernel.Contexts;       use GPS.Kernel.Contexts;
with GPS.Kernel.Console;        use GPS.Kernel.Console;
with GPS.Kernel.Hooks;          use GPS.Kernel.Hooks;
with GPS.Kernel.MDI;            use GPS.Kernel.MDI;
with GPS.Kernel.Modules;        use GPS.Kernel.Modules;
with GPS.Kernel.Preferences;    use GPS.Kernel.Preferences;
with GPS.Kernel.Project;        use GPS.Kernel.Project;
with GPS.Kernel.Scripts;        use GPS.Kernel.Scripts;
with GPS.Kernel.Standard_Hooks; use GPS.Kernel.Standard_Hooks;
with GPS.Kernel.Actions;        use GPS.Kernel.Actions;
with GPS.Intl;                  use GPS.Intl;

with Traces;                    use Traces;

with VCS;                       use VCS;
with VCS_View_API;              use VCS_View_API;
with VCS_View_Pkg;              use VCS_View_Pkg;
with Basic_Types;               use Basic_Types;
with Commands.VCS;              use Commands.VCS;

with VCS.Unknown_VCS;           use VCS.Unknown_VCS;
with VCS.Generic_VCS;           use VCS.Generic_VCS;
with Ada.Exceptions;            use Ada.Exceptions;
with GNAT.OS_Lib;               use GNAT.OS_Lib;
with Projects;                  use Projects;
with Projects.Registry;         use Projects.Registry;
with VFS;                       use VFS;

with String_List_Utils;
with Log_Utils;

package body VCS_Module is

   Auto_Detect  : constant String := "None";

   type VCS_Module_ID_Record is new Module_ID_Record with record
      VCS_List : Argument_List_Access;
      --  The list of all VCS systems recognized by the kernel

      Explorer : VCS_View_Access;
      --  The VCS Explorer

      Explorer_Child : MDI_Child;
      --  The child containing the VCS Explorer
   end record;
   type VCS_Module_ID_Access is access all VCS_Module_ID_Record'Class;

   procedure Destroy (Module : in out VCS_Module_ID_Record);
   --  Free the memory occupied by Module

   type Has_VCS_Filter is new Action_Filter_Record with null record;
   function Filter_Matches_Primitive
     (Filter  : access Has_VCS_Filter;
      Context : access Selection_Context'Class) return Boolean;
   --  True when the current context is associated with a known VCS


   procedure VCS_Contextual_Menu
     (Object  : access Glib.Object.GObject_Record'Class;
      Context : access Selection_Context'Class;
      Menu    : access Gtk.Menu.Gtk_Menu_Record'Class);
   --  Fill Menu with the contextual menu for the VCS module,
   --  if Context is appropriate.

   procedure On_Open_Interface
     (Widget : access GObject_Record'Class;
      Kernel : Kernel_Handle);
   --  Display the VCS explorer

   procedure File_Edited_Cb
     (Kernel  : access Kernel_Handle_Record'Class;
      Data    : access Hooks_Data'Class);
   --  Callback for the "file_edited" signal.

   function Load_Desktop
     (MDI  : MDI_Window;
      Node : Node_Ptr;
      User : Kernel_Handle) return MDI_Child;
   --  Restore the status of the explorer from a saved XML tree.

   function Save_Desktop
     (Widget : access Gtk.Widget.Gtk_Widget_Record'Class;
      User   : Kernel_Handle)
      return Node_Ptr;
   --  Save the status of the project explorer to an XML tree

   procedure Status_Parse_Handler
     (Data    : in out GPS.Kernel.Scripts.Callback_Data'Class;
      Command : String);
   --  Handler for the command "vcs_status_parse".

   procedure Annotations_Parse_Handler
     (Data    : in out GPS.Kernel.Scripts.Callback_Data'Class;
      Command : String);
   --  Handler for the command "VCS.annotations_parse".

   procedure VCS_Command_Handler_No_Param
     (Data    : in out GPS.Kernel.Scripts.Callback_Data'Class;
      Command : String);
   --  Handler for VCS commands that take no parameter

   -----------------------
   -- On_Open_Interface --
   -----------------------

   procedure On_Open_Interface
     (Widget : access GObject_Record'Class;
      Kernel : Kernel_Handle)
   is
      pragma Unreferenced (Widget);
   begin
      Open_Explorer (Kernel, null);

   exception
      when E : others =>
         Trace (Exception_Handle,
                "Unexpected exception: " & Exception_Information (E));
   end On_Open_Interface;

   ------------------------------
   -- Filter_Matches_Primitive --
   ------------------------------

   function Filter_Matches_Primitive
     (Filter  : access Has_VCS_Filter;
      Context : access Selection_Context'Class) return Boolean
   is
      pragma Unreferenced (Filter);
   begin
      return Context.all in File_Selection_Context'Class
        and then Get_Current_Ref (Selection_Context_Access (Context)) /=
        Unknown_VCS_Reference
        and then (Context.all not in Entity_Selection_Context'Class
                  or else Get_Name (Get_Creator (Context)) = "Source_Editor");
   end Filter_Matches_Primitive;

   -------------------------
   -- VCS_Contextual_Menu --
   -------------------------

   procedure VCS_Contextual_Menu
     (Object  : access Glib.Object.GObject_Record'Class;
      Context : access Selection_Context'Class;
      Menu    : access Gtk.Menu.Gtk_Menu_Record'Class)
   is
      pragma Unreferenced (Object);
   begin
      VCS_View_API.VCS_Contextual_Menu
        (Get_Kernel (Context),
         Selection_Context_Access (Context),
         Menu,
         False);
   end VCS_Contextual_Menu;

   ------------------
   -- Get_VCS_List --
   ------------------

   function Get_VCS_List
     (Module : Module_ID) return Argument_List is
   begin
      return VCS_Module_ID_Access (Module).VCS_List.all;
   end Get_VCS_List;

   ------------------
   -- Register_VCS --
   ------------------

   procedure Register_VCS (Module : Module_ID; VCS_Identifier : String) is
      M   : constant VCS_Module_ID_Access := VCS_Module_ID_Access (Module);
      Old : Argument_List_Access;
   begin
      if M.VCS_List = null then
         M.VCS_List := new Argument_List'(1 => new String'(VCS_Identifier));
      else
         Old := M.VCS_List;
         M.VCS_List := new Argument_List (1 .. M.VCS_List'Length + 1);
         M.VCS_List (Old'Range) := Old.all;
         M.VCS_List (M.VCS_List'Last) := new String'(VCS_Identifier);
         Basic_Types.Unchecked_Free (Old);
      end if;
   end Register_VCS;

   ----------------------------------
   -- VCS_Command_Handler_No_Param --
   ----------------------------------

   procedure VCS_Command_Handler_No_Param
     (Data    : in out GPS.Kernel.Scripts.Callback_Data'Class;
      Command : String) is
   begin
      if Command = "supported_systems" then
         declare
            Systems : constant Argument_List := Get_VCS_List (VCS_Module_ID);
         begin
            Set_Return_Value_As_List (Data);
            for S in Systems'Range loop
               if Systems (S).all = "" then
                  Set_Return_Value (Data, -Auto_Detect);
               else
                  Set_Return_Value (Data, Systems (S).all);
               end if;
            end loop;
         end;
      end if;
   end VCS_Command_Handler_No_Param;

   -------------
   -- Destroy --
   -------------

   procedure Destroy (Module : in out VCS_Module_ID_Record) is
   begin
      Free (Module.VCS_List);
   end Destroy;

   ------------------
   -- Load_Desktop --
   ------------------

   function Load_Desktop
     (MDI  : MDI_Window;
      Node : Node_Ptr;
      User : Kernel_Handle) return MDI_Child
   is
      pragma Unreferenced (MDI);
      M : constant VCS_Module_ID_Access :=
            VCS_Module_ID_Access (VCS_Module_ID);
      Explorer : VCS_View_Access;
      pragma Unreferenced (Explorer);
   begin
      if Node.Tag.all = "VCS_View_Record" then
         Explorer := Get_Explorer (User, True, True);
         return M.Explorer_Child;
      end if;

      return null;
   end Load_Desktop;

   ------------------
   -- Save_Desktop --
   ------------------

   function Save_Desktop
     (Widget : access Gtk.Widget.Gtk_Widget_Record'Class;
      User   : Kernel_Handle)
      return Node_Ptr
   is
      pragma Unreferenced (User);
      N : Node_Ptr;
   begin
      if Widget.all in VCS_View_Record'Class then
         N := new Node;
         N.Tag := new String'("VCS_View_Record");

         return N;
      end if;

      return null;
   end Save_Desktop;

   ---------------------
   -- Register_Module --
   ---------------------

   procedure Register_Module
     (Kernel : access GPS.Kernel.Kernel_Handle_Record'Class)
   is
      VCS_Class : constant Class_Type := New_Class (Kernel, "VCS");

      VCS_Root  : constant String := -"VCS";
      Command : Generic_Kernel_Command_Access;

      VCS_Action_Context : constant Action_Filter :=
        Action_Filter (Create);

      File_Filter : constant Action_Filter := Lookup_Filter (Kernel, "File");
      Dir_Filter : constant Action_Filter :=
        Lookup_Filter (Kernel, "Directory");
      Prj_Filter : constant Action_Filter :=
        Lookup_Filter (Kernel, "Project");

      Filter : Action_Filter;
      Mitem  : Gtk_Menu_Item;

      procedure Register_Action_Menu
        (Action_Label : String;
         Description  : String;
         Menu_Label   : String;
         Filter       : Action_Filter;
         Callback     : Context_Callback.Marshallers.Void_Marshaller.Handler);
      --  Registers an action and a menu

      --------------------------
      -- Register_Action_Menu --
      --------------------------

      procedure Register_Action_Menu
        (Action_Label : String;
         Description  : String;
         Menu_Label   : String;
         Filter       : Action_Filter;
         Callback     : Context_Callback.Marshallers.Void_Marshaller.Handler)
      is
         Parent_String : Basic_Types.String_Access;
      begin
         Create (Command, Kernel_Handle (Kernel), Callback);
         Register_Action (Kernel, Action_Label, Command, Description, Filter);

         if Filter = Dir_Filter then
            Parent_String := new String'("/" & (-"Directory"));
         elsif Filter = Prj_Filter then
            Parent_String := new String'("/" & (-"Project"));
         else
            Parent_String := new String'("");
         end if;

         Register_Menu
           (Kernel      => Kernel,
            Parent_Path => "/_" & VCS_Root & Parent_String.all,
            Text        => Menu_Label,
            Callback    => null,
            Action      => Lookup_Action (Kernel, Action_Label));

         Free (Parent_String);
      end Register_Action_Menu;

   begin
      VCS_Module_ID := new VCS_Module_ID_Record;
      Register_Module
        (Module                  => VCS_Module_ID,
         Kernel                  => Kernel,
         Module_Name             => VCS_Module_Name,
         Priority                => Default_Priority,
         Default_Context_Factory => VCS_View_API.Context_Factory'Access);

      GPS.Kernel.Kernel_Desktop.Register_Desktop_Functions
        (Save_Desktop'Access, Load_Desktop'Access);

      Filter := new Has_VCS_Filter;
      Register_Filter (Kernel, Filter, "VCS");

      Register_Contextual_Submenu
        (Kernel  => Kernel,
         Name    => "Version Control",
         Filter  => Filter,
         Submenu => VCS_Contextual_Menu'Access);

      Log_Utils.Initialize (Kernel);

      Standard.VCS.Unknown_VCS.Register_Module (Kernel);
      Standard.VCS.Generic_VCS.Register_Module (Kernel);

      Add_Hook (Kernel, File_Edited_Hook, File_Edited_Cb'Access);

      --  Register VCS commands.

      Register_Command
        (Kernel, "supported_systems",
         Class         => VCS_Class,
         Static_Method => True,
         Handler       => VCS_Command_Handler_No_Param'Access);
      Register_Command
        (Kernel, "get_status",
         Minimum_Args  => 1,
         Maximum_Args  => 1,
         Class         => VCS_Class,
         Static_Method => True,
         Handler       => VCS_Command_Handler'Access);
      Register_Command
        (Kernel, "update",
         Minimum_Args  => 1,
         Maximum_Args  => 1,
         Class         => VCS_Class,
         Static_Method => True,
         Handler       => VCS_Command_Handler'Access);
      Register_Command
        (Kernel, "commit",
         Minimum_Args  => 1,
         Maximum_Args  => 1,
         Class         => VCS_Class,
         Static_Method => True,
         Handler       => VCS_Command_Handler'Access);
      Register_Command
        (Kernel, "diff_head",
         Minimum_Args  => 1,
         Maximum_Args  => 1,
         Class         => VCS_Class,
         Static_Method => True,
         Handler       => VCS_Command_Handler'Access);
      Register_Command
        (Kernel, "diff_working",
         Minimum_Args  => 1,
         Maximum_Args  => 1,
         Class         => VCS_Class,
         Static_Method => True,
         Handler       => VCS_Command_Handler'Access);
      Register_Command
        (Kernel, "annotate",
         Minimum_Args  => 1,
         Maximum_Args  => 1,
         Class         => VCS_Class,
         Static_Method => True,
         Handler       => VCS_Command_Handler'Access);
      Register_Command
        (Kernel, "remove_annotations",
         Minimum_Args  => 1,
         Maximum_Args  => 1,
         Class         => VCS_Class,
         Static_Method => True,
         Handler       => VCS_Command_Handler'Access);
      Register_Command
        (Kernel, "log",
         Minimum_Args  => 1,
         Maximum_Args  => 2,
         Class         => VCS_Class,
         Static_Method => True,
         Handler       => VCS_Command_Handler'Access);
      Register_Command
        (Kernel, "status_parse",
         Minimum_Args  => 4,
         Maximum_Args  => 5,
         Class         => VCS_Class,
         Static_Method => True,
         Handler       => Status_Parse_Handler'Access);
      Register_Command
        (Kernel, "annotations_parse",
         Minimum_Args  => 3,
         Maximum_Args  => 3,
         Class         => VCS_Class,
         Static_Method => True,
         Handler       => Annotations_Parse_Handler'Access);

      --  Register the main VCS menu and the VCS actions.

      Register_Filter (Kernel, VCS_Action_Context, "VCS");

      Register_Menu
        (Kernel, "/_" & VCS_Root,
         Ref_Item => -"Navigate",
         Add_Before => False);

      Gtk_New_With_Mnemonic (Mitem, -"_Explorer");
      Kernel_Callback.Connect
        (Mitem, "activate", On_Open_Interface'Access, Kernel_Handle (Kernel));
      Register_Menu (Kernel, "/_" & VCS_Root, Mitem);

      Gtk_New_With_Mnemonic (Mitem, -"Update all _projects");
      Kernel_Callback.Connect
        (Mitem, "activate", Update_All'Access, Kernel_Handle (Kernel));
      Register_Menu (Kernel, "/_" & VCS_Root, Mitem);

      Gtk_New_With_Mnemonic (Mitem, -"_Query status for all projects");
      Kernel_Callback.Connect
        (Mitem, "activate", Query_Status_For_Project'Access,
         Kernel_Handle (Kernel));
      Register_Menu (Kernel, "/_" & VCS_Root, Mitem);

      Gtk_New (Mitem);
      Register_Menu (Kernel, "/_" & VCS_Root, Mitem);

      Register_Action_Menu
        ("Status",
         -"Query the status of the current selection",
         -"Query status",
         File_Filter,
         On_Menu_Get_Status'Access);

      Register_Action_Menu
        ("Update",
         -"Update to the current repository revision",
         -"Update",
         File_Filter,
         On_Menu_Update'Access);

      Register_Action_Menu
        ("Commit",
         -"Commit current file, or file corresponding to the current log",
         -"Commit",
         File_Filter,
         On_Menu_Commit'Access);

      Gtk_New (Mitem);
      Register_Menu (Kernel, "/_" & VCS_Root, Mitem);

      Register_Action_Menu
        ("Open",
         -"Open the current file for editing",
         -"Open",
         File_Filter,
         On_Menu_Open'Access);

      Register_Action_Menu
        ("History",
         -"View the revision history for the current file",
         -"View entire revision history",
         File_Filter,
         On_Menu_View_Log'Access);

      Register_Action_Menu
        ("History for revision....",
         -"View the revision history for one revision of the current file",
         -"View specific revision history",
         File_Filter,
         On_Menu_View_Log_Rev'Access);

      Gtk_New (Mitem);
      Register_Menu (Kernel, "/_" & VCS_Root, Mitem);

      Register_Action_Menu
        ("Diff against head",
         -"Compare current file with the most recent revision",
         -"Compare against head revision",
         File_Filter,
         On_Menu_Diff'Access);

      Register_Action_Menu
        ("Diff against revision...",
         -"Compare current file against a specified revision",
         -"Compare against specific revision",
         File_Filter,
         On_Menu_Diff_Specific'Access);

      Register_Action_Menu
        ("Diff between two revisions",
         -"Compare between two specified revisions of current file",
         -"Compare between two revisions",
         File_Filter,
         On_Menu_Diff2'Access);

      Register_Action_Menu
        ("Diff base against head",
         -"Compare between base and head revisions of current file",
         -"Compare base against head",
         File_Filter,
         On_Menu_Diff_Base_Head'Access);

      Gtk_New (Mitem);
      Register_Menu (Kernel, "/_" & VCS_Root, Mitem);

      Register_Action_Menu
        ("Annotate",
         -"Annotate the current file",
         -"Add annotations",
         File_Filter,
         On_Menu_Annotate'Access);

      Register_Action_Menu
        ("Remove Annotate",
         -"Remove the annotations from current file",
         -"Remove annotations",
         File_Filter,
         On_Menu_Remove_Annotate'Access);

      Register_Action_Menu
        ("Edit revision log",
         -"Edit the revision log for the current file",
         -"Edit revision log",
         File_Filter,
         On_Menu_Edit_Log'Access);

      Register_Action_Menu
        ("Edit global ChangeLog",
         -"Edit the global ChangeLog for the current selection",
         -"Edit global ChangeLog",
         File_Filter,
         On_Menu_Edit_ChangeLog'Access);

      Register_Action_Menu
        ("Remove revision log",
         -"Remove the revision log corresponding to the current file",
         -"Remove revision log",
         File_Filter,
         On_Menu_Remove_Log'Access);

      Gtk_New (Mitem);
      Register_Menu (Kernel, "/_" & VCS_Root, Mitem);

      Register_Action_Menu
        ("Add",
         -"Add the current file to repository",
         -"Add",
         File_Filter,
         On_Menu_Add'Access);

      Register_Action_Menu
        ("Remove",
         -"Remove the current file from repository",
         -"Remove",
         File_Filter,
         On_Menu_Remove'Access);

      Register_Action_Menu
        ("Revert",
         -"Revert the current file to repository revision",
         -"Revert",
         File_Filter,
         On_Menu_Revert'Access);

      Register_Action_Menu
        ("Resolved",
         -"Mark file conflicts resolved",
         -"Resolved",
         File_Filter,
         On_Menu_Resolved'Access);

      Gtk_New (Mitem);
      Register_Menu (Kernel, "/_" & VCS_Root, Mitem);

      Register_Action_Menu
        ("Status dir",
         -"Query the status of the current directory",
         -"Query status for directory",
         Dir_Filter,
         On_Menu_Get_Status_Dir'Access);

      Register_Action_Menu
        ("Update dir",
         -"Update the current directory",
         -"Update directory",
         Dir_Filter,
         On_Menu_Update_Dir'Access);

      Register_Action_Menu
        ("Status dir (recursively)",
         -"Query the status of the current directory recursively",
         -"Query status for directory (recursively)",
         Dir_Filter,
         On_Menu_Get_Status_Dir_Recursive'Access);

      Register_Action_Menu
        ("Update dir (recursively)",
         -"Update the current directory (recursively)",
         -"Update directory (recursively)",
         Dir_Filter,
         On_Menu_Update_Dir_Recursive'Access);

      Gtk_New (Mitem);
      Register_Menu (Kernel, "/_" & VCS_Root, Mitem);

      Register_Action_Menu
        ("List project",
         -"List all the files in project",
         -"List all files in project",
         Prj_Filter,
         On_Menu_List_Project_Files'Access);

      Register_Action_Menu
        ("Status project",
         -"Query the status of the current project",
         -"Query status",
         Prj_Filter,
         On_Menu_Get_Status_Project'Access);

      Register_Action_Menu
        ("Update project",
         -"Update the current project",
         -"Update project",
         Prj_Filter,
         On_Menu_Update_Project'Access);

      Register_Action_Menu
        ("List project (recursively)",
         -"List all the files in project and subprojects",
         -"List all files in project (recursively)",
         Prj_Filter,
         On_Menu_List_Project_Files_Recursive'Access);

      Register_Action_Menu
        ("Status project (recursively)",
         -"Query the status of the current project recursively",
         -"Query status (recursively)",
         Prj_Filter,
         On_Menu_Get_Status_Project_Recursive'Access);

      Register_Action_Menu
        ("Update project (recursively)",
         -"Update the current project (recursively)",
         -"Update project (recursively)",
         Prj_Filter,
         On_Menu_Update_Project_Recursive'Access);
   end Register_Module;

   --------------------------
   -- Status_Parse_Handler --
   --------------------------

   procedure Status_Parse_Handler
     (Data    : in out GPS.Kernel.Scripts.Callback_Data'Class;
      Command : String)
   is
      pragma Unreferenced (Command);

      Kernel : constant Kernel_Handle := Get_Kernel (Data);

      Ref    : VCS_Access;

      VCS_Identifier : constant String := Nth_Arg (Data, 1);
      S              : constant String := Nth_Arg (Data, 2);

      Clear_Logs     : constant Boolean := Nth_Arg (Data, 3);
      Local          : constant Boolean := Nth_Arg (Data, 4);
      Dir            : constant String  := Nth_Arg (Data, 5, "");

   begin
      Ref := Get_VCS_From_Id (VCS_Identifier);

      if Ref = null then
         Insert (Kernel,
                 -"Could not find registered VCS corresponding to identifier: "
                 & VCS_Identifier);
         return;
      end if;

      Parse_Status (Ref, S, Local, Clear_Logs, Dir);
   end Status_Parse_Handler;

   -------------------------------
   -- Annotations_Parse_Handler --
   -------------------------------

   procedure Annotations_Parse_Handler
     (Data    : in out GPS.Kernel.Scripts.Callback_Data'Class;
      Command : String)
   is
      pragma Unreferenced (Command);
      Kernel : constant Kernel_Handle := Get_Kernel (Data);
      Ref    : VCS_Access;
      VCS_Identifier : constant String := Nth_Arg (Data, 1);
      File           : constant VFS.Virtual_File :=
        Create (Nth_Arg (Data, 2), Kernel);
      S              : constant String := Nth_Arg (Data, 3);
   begin
      Ref := Get_VCS_From_Id (VCS_Identifier);

      if Ref = null then
         Insert (Kernel,
                 -"Could not find registered VCS corresponding to identifier: "
                 & VCS_Identifier);
         return;
      end if;

      Parse_Annotations (Ref, File, S);
   end Annotations_Parse_Handler;

   --------------------
   -- File_Edited_Cb --
   --------------------

   procedure File_Edited_Cb
     (Kernel  : access Kernel_Handle_Record'Class;
      Data    : access Hooks_Data'Class)
   is
      use String_List_Utils.String_List;
      D : constant File_Hooks_Args := File_Hooks_Args (Data.all);
      Files  : List;
      Ref    : VCS_Access;
      Status : File_Status_Record;
   begin
      Ref    := Get_Current_Ref
        (Get_Project_From_File (Get_Registry (Kernel).all, D.File, True));

      if Ref = null then
         return;
      end if;

      Status := Get_Cached_Status
        (Get_Explorer (Kernel_Handle (Kernel), False), D.File, Ref);

      if Status.File = VFS.No_File then
         Append (Files, Full_Name (D.File).all);
         Get_Status (Ref, Files, False, Local => True);
         Free (Files);
      else
         Display_Editor_Status
           (Kernel_Handle (Kernel), Ref, Status);
      end if;

   exception
      when E : others =>
         Trace (Exception_Handle,
                "Unexpected exception: " & Exception_Information (E));
   end File_Edited_Cb;

   ------------------
   -- Get_Explorer --
   ------------------

   function Get_Explorer
     (Kernel      : Kernel_Handle;
      Raise_Child : Boolean := True;
      Show        : Boolean := False) return VCS_View_Access
   is
      M : constant VCS_Module_ID_Access :=
            VCS_Module_ID_Access (VCS_Module_ID);
   begin
      if M.Explorer = null then
         Gtk_New (M.Explorer, Kernel);
      end if;

      if Show
        and then M.Explorer_Child = null
      then
         M.Explorer_Child := Put
           (Kernel, M.Explorer,
            Default_Width  => Get_Pref (Kernel, Default_Widget_Width),
            Default_Height => Get_Pref (Kernel, Default_Widget_Height),
            Position       => Position_VCS_Explorer,
            Module         => VCS_Module_ID);

         Set_Focus_Child (M.Explorer_Child);
         Set_Title (M.Explorer_Child, -"VCS Explorer");
      end if;

      if M.Explorer_Child /= null
        and then Raise_Child
      then
         Gtkada.MDI.Raise_Child (M.Explorer_Child);
      end if;

      return M.Explorer;
   end Get_Explorer;

   -----------------------
   -- Hide_VCS_Explorer --
   -----------------------

   procedure Hide_VCS_Explorer is
      M : constant VCS_Module_ID_Access :=
            VCS_Module_ID_Access (VCS_Module_ID);
   begin
      if M.Explorer = null
        or else M.Explorer_Child = null
      then
         return;
      else
         Ref (M.Explorer);
         Close_Child (M.Explorer_Child, True);
         M.Explorer_Child := null;
      end if;
   end Hide_VCS_Explorer;

   ----------------------
   -- Explorer_Is_Open --
   ----------------------

   function Explorer_Is_Open return Boolean is
      M : constant VCS_Module_ID_Access :=
            VCS_Module_ID_Access (VCS_Module_ID);
   begin
      return M.Explorer /= null
        and then M.Explorer_Child /= null;
   end Explorer_Is_Open;

end VCS_Module;

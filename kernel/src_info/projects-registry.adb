-----------------------------------------------------------------------
--                               G P S                               --
--                                                                   --
--                 Copyright (C) 2002-2010, AdaCore                  --
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

with Ada.Calendar;              use Ada.Calendar;
with Ada.Unchecked_Deallocation;
with Ada.Characters.Handling;   use Ada.Characters.Handling;
with Ada.Containers.Doubly_Linked_Lists;

with GNAT.Directory_Operations; use GNAT.Directory_Operations;
with GNAT.OS_Lib;               use GNAT.OS_Lib;
with GNATCOLL.Traces;
with GNATCOLL.Utils;            use GNATCOLL.Utils;
with GNATCOLL.VFS_Utils;        use GNATCOLL.VFS_Utils;

with ALI;
with Namet;                     use Namet;
with Opt;                       use Opt;
with Output;
with Osint;                     use Osint;
with Prj_Output;                use Prj_Output;
with Scans;                     use Scans;
with Snames;                    use Snames;
with Stringt;

with Csets;
with File_Utils;                use File_Utils;
with GPS.Intl;                  use GPS.Intl;
with OS_Utils;                  use OS_Utils;
with Prj.Com;                   use Prj.Com;
with Prj.Conf;                  use Prj.Conf;
with Prj.Env;                   use Prj.Env;
with Prj.Err;                   use Prj.Err;
with Prj.Ext;                   use Prj.Ext;
with Prj.PP;                    use Prj.PP;
with Prj.Part;                  use Prj.Part;
with Prj.Tree;                  use Prj.Tree;
with Prj;                       use Prj;
with Projects.Editor;           use Projects.Editor;
with Remote;                    use Remote;
with Sinput.P;
with String_Hash;
with Traces;                    use Traces;
with Types;                     use Types;

package body Projects.Registry is

   Me      : constant Debug_Handle := Create ("Projects.Registry");
   Me_Debug : constant Debug_Handle :=
               Create ("Projects.Registry.Debug", GNATCOLL.Traces.Off);
   Me_Gnat : constant Debug_Handle :=
               Create ("Projects.GNAT", GNATCOLL.Traces.Off);

   Project_Backward_Compatibility : constant Boolean := True;
   --  Should be set to true if saved project should be compatible with GNAT
   --  3.15a1, False if they only need to be compatible with GNAT 3.16 >=
   --  20021024

   Keywords_Initialized : Boolean := False;
   --  Whether we have already initialized the Ada keywords list. This is only
   --  used by Is_Valid_Project_Name

   Dummy_Suffix : constant String := "<no suffix defined>";
   --  A dummy suffixes that is used for languages that have either no spec or
   --  no implementation suffix defined.

   package Virtual_File_List is new Ada.Containers.Doubly_Linked_Lists
     (Element_Type => Virtual_File);
   use Virtual_File_List;

   procedure Do_Nothing (Project : in out Project_Type) is null;
   --  Do not free the project (in the hash tables), since it shared by several
   --  entries and several htables

   package Project_Htable is new String_Hash
     (Data_Type      => Project_Type,
      Free_Data      => Do_Nothing,
      Null_Ptr       => No_Project,
      Case_Sensitive => False);
   use Project_Htable.String_Hash_Table;

   type Directory_Dependency is (Direct, As_Parent, None);
   --  The way a directory belongs to the project: either as a direct
   --  dependency, or because one of its subdirs belong to the project, or
   --  doesn't belong at all.

   procedure Do_Nothing (Dep : in out Directory_Dependency) is null;
   package Directory_Htable is new String_Hash
     (Data_Type      => Directory_Dependency,
      Free_Data      => Do_Nothing,
      Null_Ptr       => None,
      Case_Sensitive => Is_Case_Sensitive (Get_Nickname (Build_Server)));
   use Directory_Htable.String_Hash_Table;

   type Source_File_Data is record
      Project   : Project_Type;
      File      : GNATCOLL.VFS.Virtual_File;
      Lang      : Name_Id;
      Source    : Source_Id;
   end record;
   No_Source_File_Data : constant Source_File_Data :=
     (No_Project, GNATCOLL.VFS.No_File, No_Name, No_Source);
   --   In some case, Lang might be set to Unknown_Language, if the file was
   --   set in the project (for instance through the Source_Files attribute),
   --   but no matching language was found.

   procedure Do_Nothing (Data : in out Source_File_Data) is null;
   package Source_Htable is new String_Hash
     (Data_Type      => Source_File_Data,
      Free_Data      => Do_Nothing,
      Null_Ptr       => No_Source_File_Data,
      Case_Sensitive => Is_Case_Sensitive (Get_Nickname (Build_Server)));
   use Source_Htable.String_Hash_Table;

   procedure Do_Nothing (Name : in out Name_Id) is null;
   package Languages_Htable is new String_Hash
     (Data_Type => Name_Id,
      Free_Data => Do_Nothing,
      Null_Ptr  => No_Name);
   use Languages_Htable.String_Hash_Table;

   type Naming_Scheme_Record;
   type Naming_Scheme_Access is access Naming_Scheme_Record;
   type Naming_Scheme_Record is record
      Language            : GNAT.Strings.String_Access;
      Default_Spec_Suffix : GNAT.Strings.String_Access;
      Default_Body_Suffix : GNAT.Strings.String_Access;
      Next                : Naming_Scheme_Access;
   end record;

   type Project_Registry_Data is record
      Tree      : Prj.Tree.Project_Node_Tree_Ref;
      View_Tree : Prj.Project_Tree_Ref;
      --  The description of the trees

      Root    : Project_Type := No_Project;
      --  The root of the project hierarchy

      Sources : Source_Htable.String_Hash_Table.Instance;
      --  Index on base source file names, return the managing project

      Directories : Directory_Htable.String_Hash_Table.Instance;
      --  Index on directory name

      Projects : Project_Htable.String_Hash_Table.Instance;
      --  Index on project names. Some project of the hierarchy might not
      --  exist, since the Project_Type are created lazily the first time they
      --  are needed.

      Naming_Schemes : Naming_Scheme_Access;
      --  The list of default naming schemes for the languages known to GPS

      Scenario_Variables : Scenario_Variable_Array_Access;
      --  Cached value of the scenario variables. This should be accessed only
      --  through the function Scenario_Variables, since it needs to be
      --  initialized first.

      Predefined_Object_Path : File_Array_Access;
      --  Predefined object path for the runtime library

      Predefined_Source_Path : File_Array_Access;
      --  Predefined source paths for the runtime library

      Predefined_Source_Files : GNATCOLL.VFS.File_Array_Access;
      --  The list of source files in Predefined_Source_Path

      Xrefs_Subdir : GNAT.Strings.String_Access;
      --  Object dirs subdirectory containing the cross-refs

      Extensions : Languages_Htable.String_Hash_Table.Instance;
      --  The extensions registered for each language

      Timestamp : Ada.Calendar.Time;
      --  Time when we last parsed the project from the disk

      Trusted_Mode : Boolean := True;
      --  Whether we are in trusted mode when recomputing the project view
   end record;

   procedure Reset
     (Registry  : in out Project_Registry;
      View_Only : Boolean);
   --  Reset the contents of the project registry. This should be called only
   --  if a new project is loaded, otherwise no project is accessible to the
   --  application any more.
   --  If View_Only is true, then the projects are not destroyed, but all the
   --  fields related to the current view are reset.

   procedure Create_Environment_Variables (Registry : in out Project_Registry);
   --  Make sure that all the environment variables actually exist (possibly
   --  with their default value). Otherwise, GNAT will not be able to compute
   --  the project view.

   procedure Reset_Environment_Variables (Registry : Project_Registry);
   --  Find all the environment variables for the project, and cache the list
   --  in the registry.
   --  Does nothing if the cache is not empty.

   procedure Parse_Source_Files (Registry : in out Project_Registry);
   --  Find all the source files for the project, and cache them in the
   --  registry.
   --  At the same time, check that the gnatls attribute is coherent between
   --  all projects and subprojects, and memorize the sources in the
   --  hash-table.

   procedure Add_Runtime_Files
     (Registry : in out Project_Registry; Path : File_Array);
   --  Add all runtime files to the caches

   procedure Unchecked_Free is new Ada.Unchecked_Deallocation
     (Scenario_Variable_Array, Scenario_Variable_Array_Access);
   procedure Unchecked_Free is new Ada.Unchecked_Deallocation
     (Naming_Scheme_Record, Naming_Scheme_Access);

   function String_Elements
     (R : Project_Registry) return Prj.String_Element_Table.Table_Ptr;
   pragma Inline (String_Elements);
   --  Return access to the various tables that contain information about the
   --  project

   procedure Internal_Load
     (Registry          : Project_Registry;
      Root_Project_Path : GNATCOLL.VFS.Virtual_File;
      Errors            : Projects.Error_Report;
      Project           : out Project_Node_Id);
   --  Internal implementation of load. This doesn't reset the registry at all,
   --  but will properly setup the GNAT project manager so that error messages
   --  are redirected and fatal errors do not kill GPS

   procedure Do_Subdirs_Cleanup (Registry : Project_Registry);
   --  Cleanup empty subdirs created when opening a project with prj.subdirs
   --  set.

   generic
      Registry : Project_Registry;
   procedure Mark_Project_Error (Project : Project_Id; Is_Warning : Boolean);
   --  Handler called when the project parser finds an error.
   --  Mark_Project_Incomplete should be true if any error should prevent the
   --  edition of project properties graphically.

   ------------------------
   -- Mark_Project_Error --
   ------------------------

   procedure Mark_Project_Error (Project : Project_Id; Is_Warning : Boolean) is
      P : Project_Type;
   begin
      if not Is_Warning then
         if Project = Prj.No_Project then
            if Registry.Data.Root /= No_Project then
               declare
                  Iter : Imported_Project_Iterator :=
                           Start (Registry.Data.Root);
               begin
                  while Current (Iter) /= No_Project loop
                     Set_View_Is_Complete (Current (Iter), False);
                     Next (Iter);
                  end loop;
               end;
            end if;

         else
            P := Get_Project_From_Name (Registry, Project.Name);
            Set_View_Is_Complete (P, False);
         end if;
      end if;
   end Mark_Project_Error;

   ---------------------
   -- String_Elements --
   ---------------------

   function String_Elements
     (R : Project_Registry) return Prj.String_Element_Table.Table_Ptr is
   begin
      return R.Data.View_Tree.String_Elements.Table;
   end String_Elements;

   ---------------------------
   -- Is_Valid_Project_Name --
   ---------------------------

   function Is_Valid_Project_Name (Name : String) return Boolean is
   begin
      if Name'Length = 0
        or else (Name (Name'First) not in 'a' .. 'z'
                 and then Name (Name'First) not in 'A' .. 'Z')
      then
         return False;
      end if;

      for N in Name'First + 1 .. Name'Last loop
         if Name (N) not in 'a' .. 'z'
           and then Name (N) not in 'A' .. 'Z'
           and then Name (N) not in '0' .. '9'
           and then Name (N) /= '_'
           and then Name (N) /= '.'
         then
            return False;
         end if;
      end loop;

      if not Keywords_Initialized then
         Scans.Initialize_Ada_Keywords;
         Keywords_Initialized := True;
      end if;

      if Is_Keyword_Name (Get_String (Name)) then
         return False;
      end if;

      return True;
   end Is_Valid_Project_Name;

   ----------------------
   -- Set_Trusted_Mode --
   ----------------------

   procedure Set_Trusted_Mode
     (Registry     : Project_Registry'Class;
      Trusted_Mode : Boolean) is
   begin
      Registry.Data.Trusted_Mode := Trusted_Mode;
      Opt.Follow_Links_For_Files := not Registry.Data.Trusted_Mode;
      Opt.Follow_Links_For_Dirs := Opt.Follow_Links_For_Files;
      GNATCOLL.VFS.Symbolic_Links_Support
        (Active => Opt.Follow_Links_For_Files);
   end Set_Trusted_Mode;

   ----------------------
   -- Get_Trusted_Mode --
   ----------------------

   function Get_Trusted_Mode
     (Registry : Project_Registry'Class) return Boolean is
   begin
      return Registry.Data.Trusted_Mode;
   end Get_Trusted_Mode;

   ------------------------------------
   -- Reset_Scenario_Variables_Cache --
   ------------------------------------

   procedure Reset_Scenario_Variables_Cache (Registry : Project_Registry) is
   begin
      Unchecked_Free (Registry.Data.Scenario_Variables);
   end Reset_Scenario_Variables_Cache;

   ----------------------
   -- Reset_Name_Table --
   ----------------------

   procedure Reset_Name_Table
     (Registry           : Project_Registry;
      Project            : Project_Type;
      Old_Name, New_Name : String) is
   begin
      if Registry.Data /= null then
         Set (Registry.Data.Projects, New_Name, Project);
         Remove (Registry.Data.Projects, Old_Name);
      end if;
   end Reset_Name_Table;

   --------------------
   -- Unload_Project --
   --------------------

   procedure Unload_Project
     (Registry : Project_Registry; View_Only : Boolean := False)
   is
      Project : Project_Type;
      Iter    : Project_Htable.String_Hash_Table.Cursor;
   begin
      if Registry.Data /= null then
         --  Free all projects

         Get_First (Registry.Data.Projects, Iter);
         loop
            Project := Get_Element (Iter);
            exit when Project = No_Project;

            if View_Only then
               Reset (Project);
            else
               Destroy (Project);
            end if;
            Get_Next (Registry.Data.Projects, Iter);
         end loop;

         if not View_Only then
            Reset (Registry.Data.Projects);

            --  We should not reset the environment variables, which might have
            --  been set by the user already.
            --  Prj.Ext.Reset (Registry.Data.Tree);

            Reset (Registry.Data.View_Tree);
            Prj.Tree.Tree_Private_Part.Projects_Htable.Reset
              (Registry.Data.Tree.Projects_HT);
            Registry.Data.Root := No_Project;
            Sinput.P.Clear_Source_File_Table;
            Sinput.P.Reset_First;
         end if;

         Unchecked_Free (Registry.Data.Predefined_Source_Files);
         Reset (Registry.Data.Sources);
         Reset (Registry.Data.Directories);
         Reset_Scenario_Variables_Cache (Registry);
      end if;
   end Unload_Project;

   -----------
   -- Reset --
   -----------

   procedure Reset
     (Registry  : in out Project_Registry;
      View_Only : Boolean)
   is
      Naming : Naming_Scheme_Access;
   begin
      if Registry.Data /= null then
         Do_Subdirs_Cleanup (Registry);
         Unload_Project (Registry, View_Only);
      else
         Registry.Data           := new Project_Registry_Data;
         Registry.Data.Tree      := new Project_Node_Tree_Data;
         Registry.Data.View_Tree := new Project_Tree_Data;
         Reset (Registry.Data.Sources);
         Reset (Registry.Data.Directories);
         Set_Trusted_Mode
           (Registry, Trusted_Mode => Registry.Data.Trusted_Mode);
      end if;

      if not View_Only then
         Prj.Tree.Initialize (Registry.Data.Tree);
      end if;

      Prj.Initialize (Registry.Data.View_Tree);

      if View_Only then
         Naming := Registry.Data.Naming_Schemes;
         while Naming /= null loop
            Add_Language_Extension
              (Registry, Naming.Language.all, Naming.Default_Spec_Suffix.all);
            Add_Language_Extension
              (Registry, Naming.Language.all, Naming.Default_Body_Suffix.all);
            Naming := Naming.Next;
         end loop;
      end if;
   end Reset;

   ------------------
   -- Load_Or_Find --
   ------------------

   function Load_Or_Find
     (Registry     : Project_Registry;
      Project_Name : String;
      Errors       : Projects.Error_Report) return Project_Type
   is
      File : Virtual_File;
   begin
      --  We just create a dummy file with the raw project name as path.
      --  This is correctly handled later in the body of the other
      --  Load_Or_Find method.
      File := Create (+Project_Name);
      return Load_Or_Find (Registry, File, Errors);
   end Load_Or_Find;

   ------------------
   -- Load_Or_Find --
   ------------------

   function Load_Or_Find
     (Registry     : Project_Registry;
      Project_Path : Virtual_File;
      Errors       : Projects.Error_Report) return Project_Type
   is
      Path : constant Filesystem_String :=
               Base_Name (Project_Path, Project_File_Extension);
      P    : Project_Type;
      Node : Project_Node_Id;
   begin
      Name_Len := Path'Length;
      Name_Buffer (1 .. Name_Len) := +Path;
      P := Get_Project_From_Name (Registry, Name_Find);
      if P = No_Project then
         Internal_Load
           (Registry           => Registry,
            Root_Project_Path  => Project_Path,
            Errors             => Errors,
            Project            => Node);
         P := Get_Project_From_Name
           (Registry, Prj.Tree.Name_Of (Node, Registry.Data.Tree));
      end if;

      return P;
   end Load_Or_Find;

   -------------------
   -- Internal_Load --
   -------------------

   procedure Internal_Load
     (Registry           : Project_Registry;
      Root_Project_Path  : GNATCOLL.VFS.Virtual_File;
      Errors             : Projects.Error_Report;
      Project            : out Project_Node_Id)
   is
      procedure On_Error is new Mark_Project_Error (Registry);
      --  Any error while parsing the project marks it as incomplete, and
      --  prevents direct edition of the project.

      procedure Fail (S : String);
      --  Replaces Osint.Fail

      ----------
      -- Fail --
      ----------

      procedure Fail (S : String) is
      begin
         if Errors /= null then
            Errors (S);
         end if;
      end Fail;

      Predefined_Path : constant String :=
                          +To_Path (Get_Predefined_Project_Path (Registry));
   begin
      Trace (Me, "Set project path to " & Predefined_Path);
      Prj.Ext.Set_Project_Path (Registry.Data.Tree, Predefined_Path);

      Project := Empty_Node;
      --  Make sure errors are reinitialized before load
      Prj.Err.Initialize;

      Prj_Output.Set_Special_Output (Output.Output_Proc (Errors));
      Prj.Com.Fail := Fail'Unrestricted_Access;

      Sinput.P.Clear_Source_File_Table;
      Sinput.P.Reset_First;
      Prj.Part.Parse
        (Registry.Data.Tree, Project,
         +Root_Project_Path.Full_Name,
         True,
         Store_Comments    => True,
         Is_Config_File    => False,
         Flags             => Create_Flags (On_Error'Unrestricted_Access),
         Current_Directory => Get_Current_Dir);

      Prj.Com.Fail := null;
      Prj_Output.Cancel_Special_Output;

   exception
      when E : others =>
         Trace (Exception_Handle, E);
         Prj.Com.Fail := null;
         Prj_Output.Cancel_Special_Output;
         raise;
   end Internal_Load;

   ----------
   -- Load --
   ----------

   procedure Load
     (Registry           : in out Project_Registry;
      Root_Project_Path  : GNATCOLL.VFS.Virtual_File;
      Errors             : Projects.Error_Report;
      New_Project_Loaded : out Boolean;
      Status             : out Boolean)
   is
      Previous_Project : Virtual_File;
      Previous_Default : Boolean;
      Iter             : Imported_Project_Iterator;
      Timestamp        : Time;
      Success          : Boolean;
      Project          : Project_Node_Id;

   begin
      --  Activate Traces. They will unfortunately be output on stdout,
      --  but this is a convenient way to at least get them.

      if Active (Me_Gnat) then
         Prj.Current_Verbosity := Prj.High;
      end if;

      Status := True;

      if Registry.Data /= null
        and then Registry.Data.Root /= No_Project
      then
         Previous_Project := Project_Path (Registry.Data.Root);
         Previous_Default := Projects.Status (Registry.Data.Root) = Default;

      else
         Previous_Project := GNATCOLL.VFS.No_File;
         Previous_Default := False;
      end if;

      if not Is_Regular_File (Root_Project_Path) then
         Trace (Me, "Load: " & Display_Full_Name (Root_Project_Path)
                & " is not a regular file");

         if Errors /= null then
            Errors (Display_Full_Name (Root_Project_Path)
                    & (-" is not a regular file"));
         end if;

         New_Project_Loaded := False;
         Status := False;
         return;
      end if;

      Reset (Registry, View_Only => False);

      Internal_Load (Registry, Root_Project_Path, Errors, Project);

      if Project = Empty_Node then
         New_Project_Loaded := False;

         --  Reset the list of error messages
         Prj.Err.Initialize;
         Load_Empty_Project (Registry);
         Status := False;
         return;
      end if;

      New_Project_Loaded := True;

      Registry.Data.Root := Get_Project_From_Name
        (Registry, Prj.Tree.Name_Of (Project, Registry.Data.Tree));
      Unchecked_Free (Registry.Data.Scenario_Variables);

      Set_Status (Registry.Data.Root, From_File);

      --  We cannot simply use Clock here, since this returns local time,
      --  and the file timestamps will be returned in GMT, therefore we
      --  won't be able to compare.

      Registry.Data.Timestamp := GNATCOLL.Utils.No_Time;
      Iter := Start (Registry.Data.Root);

      while Current (Iter) /= No_Project loop
         Timestamp := File_Time_Stamp (Project_Path (Current (Iter)));

         if Timestamp > Registry.Data.Timestamp then
            Registry.Data.Timestamp := Timestamp;
         end if;

         Next (Iter);
      end loop;

      if Previous_Default then
         Trace (Me, "Remove default project on disk, no longer used");
         Delete (Previous_Project, Success);
      end if;

      Trace (Me, "End of Load project");
   end Load;

   ----------------------
   -- Reload_If_Needed --
   ----------------------

   procedure Reload_If_Needed
     (Registry : in out Project_Registry;
      Errors   : Projects.Error_Report;
      Reloaded : out Boolean)
   is
      Iter               : Imported_Project_Iterator;
      New_Project_Loaded : Boolean;
      Status             : Boolean;
   begin
      Iter     := Start (Registry.Data.Root);
      Reloaded := False;

      while Current (Iter) /= No_Project loop
         if File_Time_Stamp (Project_Path (Current (Iter))) >
           Registry.Data.Timestamp
         then
            Trace (Me, "Reload_If_Needed: timestamp has changed for "
                   & Project_Name (Current (Iter)));
            Reloaded := True;
            exit;
         end if;

         Next (Iter);
      end loop;

      if Reloaded then
         Load
           (Registry           => Registry,
            Root_Project_Path  => Project_Path (Registry.Data.Root),
            Errors             => Errors,
            New_Project_Loaded => New_Project_Loaded,
            Status             => Status);
      else
         Trace (Me, "Reload_If_Needed: nothing to do, timestamp unchanged");
      end if;
   end Reload_If_Needed;

   -------------------------
   -- Load_Custom_Project --
   -------------------------

   procedure Load_Custom_Project
     (Registry : Project_Registry;
      Project  : Project_Type) is
   begin
      Registry.Data.Root := Project;
      Set_Project_Modified (Registry.Data.Root, False);
   end Load_Custom_Project;

   ------------------------
   -- Load_Empty_Project --
   ------------------------

   procedure Load_Empty_Project (Registry : in out Project_Registry) is
      Project : Project_Type;
   begin
      Reset (Registry, View_Only => False);
      Prj.Tree.Initialize (Registry.Data.Tree);
      Project := Create_Project (Registry, "empty", Get_Current_Dir);

      --  No language known for empty project

      Update_Attribute_Value_In_Scenario
        (Project            => Project,
         Scenario_Variables => No_Scenario,
         Attribute          => Languages_Attribute,
         Values             => (1 .. 0 => null));

      Load_Custom_Project (Registry, Project);

      Set_Status (Registry.Data.Root, Empty);
   end Load_Empty_Project;

   --------------------
   -- Recompute_View --
   --------------------

   procedure Recompute_View
     (Registry : in out Project_Registry;
      Errors   : Projects.Error_Report)
   is
      procedure Add_GPS_Naming_Schemes_To_Config_File
        (Config_File  : in out Project_Node_Id;
         Project_Tree : Project_Node_Tree_Ref);
      --  Add the naming schemes defined in GPS's configuration files to the
      --  configuration file (.cgpr) used to parse the project.

      procedure On_Error is new Mark_Project_Error (Registry);
      --  Any error while processing the project marks it as incomplete, and
      --  prevents direct edition of the project.

      -------------------------------------------
      -- Add_GPS_Naming_Schemes_To_Config_File --
      -------------------------------------------

      procedure Add_GPS_Naming_Schemes_To_Config_File
        (Config_File  : in out Project_Node_Id;
         Project_Tree : Project_Node_Tree_Ref)
      is
         NS : Naming_Scheme_Access := Registry.Data.Naming_Schemes;
      begin
         if Config_File = Empty_Node then
            --  Create a dummy config file is none was found. In that case we
            --  need to provide the Ada naming scheme as well

            Trace (Me, "Creating dummy configuration file");

            Add_Default_GNAT_Naming_Scheme
              (Config_File, Project_Tree);

            --  Pretend we support shared and static libs. Since we are not
            --  trying to build anyway, this isn't dangerous, and allows
            --  loading some libraries projects which otherwise we could not
            --  load.
            Update_Attribute_Value_In_Scenario
              (Tree               => Project_Tree,
               Project            => Config_File,
               Scenario_Variables => No_Scenario,
               Attribute          => "library_support",
               Value              => "full");
         end if;

         while NS /= null loop
            if NS.Default_Spec_Suffix.all /= Dummy_Suffix then
               Update_Attribute_Value_In_Scenario
                 (Tree               => Project_Tree,
                  Project            => Config_File,
                  Scenario_Variables => No_Scenario,
                  Attribute          => Spec_Suffix_Attribute,
                  Value              => NS.Default_Spec_Suffix.all,
                  Attribute_Index    => NS.Language.all);
            end if;

            if NS.Default_Body_Suffix.all /= Dummy_Suffix then
               Update_Attribute_Value_In_Scenario
                 (Tree               => Project_Tree,
                  Project            => Config_File,
                  Scenario_Variables => No_Scenario,
                  Attribute          => Impl_Suffix_Attribute,
                  Value              => NS.Default_Body_Suffix.all,
                  Attribute_Index    => NS.Language.all);
            end if;

            NS := NS.Next;
         end loop;
      end Add_GPS_Naming_Schemes_To_Config_File;

      View                    : Project_Id;
      Iter                    : Imported_Project_Iterator :=
                                  Start (Registry.Data.Root);
      Automatically_Generated : Boolean;
      Config_File_Path        : String_Access;
      Flags                   : Processing_Flags;

   begin
      while Current (Iter) /= No_Project loop
         Set_View_Is_Complete (Current (Iter), True);
         Next (Iter);
      end loop;

      Reset (Registry, View_Only => True);

      Unchecked_Free (Registry.Data.Scenario_Variables);

      Create_Environment_Variables (Registry);

      begin
         Flags := Create_Flags
           (On_Error'Unrestricted_Access, Require_Sources => False);

         --  Make sure errors are reinitialized before load
         Prj.Err.Initialize;

         Process_Project_And_Apply_Config
           (Main_Project               => View,
            User_Project_Node          => Registry.Data.Root.Node,
            Config_File_Name           => "",
            Autoconf_Specified         => False,
            Project_Tree               => Registry.Data.View_Tree,
            Project_Node_Tree          => Registry.Data.Tree,
            Packages_To_Check          => null,
            Allow_Automatic_Generation => False,
            Automatically_Generated    => Automatically_Generated,
            Config_File_Path           => Config_File_Path,
            Flags                      => Flags,
            Normalized_Hostname        => "",
            On_Load_Config             =>
              Add_GPS_Naming_Schemes_To_Config_File'Unrestricted_Access);
      exception
         when Invalid_Config =>
            --  Error message was already reported via Prj.Err
            null;
      end;

      Parse_Source_Files (Registry);

      --  ??? Should not be needed since all errors are reported through the
      --  callback already. This avoids duplicate error messages in the console

      Prj_Output.Set_Special_Output (Output.Output_Proc (Errors));
      Prj.Err.Finalize;
      Prj_Output.Cancel_Special_Output;

   exception
      --  We can get an unexpected exception (actually Directory_Error) if the
      --  project file's path is invalid, for instance because it was
      --  modified by the user.
      when E : others => Trace (Exception_Handle, E);
   end Recompute_View;

   ------------------------
   -- Parse_Source_Files --
   ------------------------

   procedure Parse_Source_Files (Registry : in out Project_Registry) is
      procedure Register_Directory (Directory : Filesystem_String);
      --  Register Directory as belonging to Project.
      --  The parent directories are also registered.

      ------------------------
      -- Register_Directory --
      ------------------------

      procedure Register_Directory (Directory : Filesystem_String) is
         Dir  : constant Filesystem_String := Name_As_Directory (Directory);
         Last : Integer := Dir'Last - 1;
      begin
         Set (Registry.Data.Directories, K => +Dir, E => Direct);

         loop
            while Last >= Dir'First
              and then not OS_Utils.Is_Directory_Separator (Dir (Last))
            loop
               Last := Last - 1;
            end loop;

            Last := Last - 1;

            exit when Last <= Dir'First;

            --  Register the name with a trailing directory separator
            if Get (Registry.Data.Directories,
                    +Dir (Dir'First .. Last + 1)) /= Direct
            then
               Set (Registry.Data.Directories,
                    K => +Dir (Dir'First .. Last + 1), E => As_Parent);
            end if;
         end loop;
      end Register_Directory;

      Gnatls           : constant String :=
                           Get_Attribute_Value
                             (Registry.Data.Root, Gnatlist_Attribute);
      Iter             : Imported_Project_Iterator :=
                           Start (Registry.Data.Root, True);
      Sources          : String_List_Id;
      P                : Project_Type;
      Source_Iter      : Source_Iterator;
      Source           : Source_Id;
      Source_File_List : Virtual_File_List.List;

   begin
      loop
         P := Current (Iter);
         exit when P = No_Project;

         declare
            Ls : constant String :=
                   Get_Attribute_Value (P, Gnatlist_Attribute);
         begin
            if Ls /= "" and then Ls /= Gnatls then
               --  We do not want to mark the project as incomplete for this
               --  warning, so we do not need to pass an actual Error_Handler
               Prj.Err.Error_Msg
                 (Flags => Create_Flags (null),
                  Msg   =>
                   -("?the project attribute IDE.gnatlist doesn't have"
                    & " the same value as in the root project."
                    & " The value """ & Gnatls & """ will be used"),
                  Project => Get_View (P));
            end if;
         end;

         --  Reset the list of source files for this project. We must not
         --  Free it, since it is now stored in the previous project's instance

         Source_File_List := Virtual_File_List.Empty_List;

         --  Add the directories

         Sources := Get_View (P).Source_Dirs;
         while Sources /= Nil_String loop
            Register_Directory
              (+Get_String (String_Elements (Registry)(Sources).Value));
            Sources := String_Elements (Registry)(Sources).Next;
         end loop;

         Register_Directory (+Get_String (Get_View (P).Object_Directory.Name));
         Register_Directory (+Get_String (Get_View (P).Exec_Directory.Name));

         --  Add the sources that are already in the project.
         --  Convert the names to UTF8 for proper handling in GPS

         Source_Iter := For_Each_Source
           (Registry.Data.View_Tree, Get_View (P));
         loop
            Source := Element (Source_Iter);
            exit when Source = No_Source;

            --  Get the absolute path name for this source
            Get_Name_String (Source.Path.Display_Name);

            declare
               File : constant Virtual_File :=
                        Create (+Name_Buffer (1 .. Name_Len));
            begin
               Set (Registry.Data.Sources,
                    K => +Base_Name (File),
                    E => (P, File, Source.Language.Name, Source));

               --  The project manager duplicates files that contain several
               --  units. Only add them once in the project sources (and thus
               --  only when the Index is 0 (single unit) or 1 (first of
               --  multiple units)
               --  For source-based languages, we allow duplicate sources

               if Source.Unit = null or else Source.Index <= 1 then
                  Prepend (Source_File_List, File);
               end if;
            end;

            Next (Source_Iter);
         end loop;

         --  Register the sources in our own caches

         declare
            Count   : constant Ada.Containers.Count_Type :=
                        Virtual_File_List.Length (Source_File_List);
            Files   : constant File_Array_Access :=
                        new File_Array (1 .. Natural (Count));
            Current : Virtual_File_List.Cursor := First (Source_File_List);
            J       : Natural := Files'First;
         begin
            while Has_Element (Current) loop
               Files (J) := Element (Current);
               Next (Current);
               J := J + 1;
            end loop;

            Set_Source_Files (P, Files);
         end;

         Next (Iter);
      end loop;
   end Parse_Source_Files;

   -----------------------
   -- Add_Runtime_Files --
   -----------------------

   procedure Add_Runtime_Files
     (Registry : in out Project_Registry; Path : File_Array)
   is
      Info  : Source_File_Data;
      Files : File_Array_Access;
   begin
      for J in Path'Range loop
         begin
            if Is_Directory (Path (J)) then
               Files := Read_Dir (Path (J));

               for K in Files'Range loop
                  if +File_Extension (Files (K)) = ".ads"
                    or else +File_Extension (Files (K)) = ".adb"
                  then
                     --  Do not override runtime files that are in the
                     --  current project
                     Info :=
                       Get (Registry.Data.Sources, +Base_Name (Files (K)));
                     if Info.Source = No_Source then
                        Set
                          (Registry.Data.Sources,
                           K => +Base_Name (Files (K)),
                           E => (No_Project, Files (K), Name_Ada, No_Source));
                     end if;
                  end if;
               end loop;

               Unchecked_Free (Files);
            end if;

         exception
            when VFS_Directory_Error =>
               Trace (Me, "Directory_Error while opening "
                      & Path (J).Display_Full_Name);
         end;
      end loop;
   end Add_Runtime_Files;

   ----------------------------------
   -- Create_Environment_Variables --
   ----------------------------------

   procedure Create_Environment_Variables
     (Registry : in out Project_Registry) is
   begin
      Reset_Environment_Variables (Registry);

      for J in Registry.Data.Scenario_Variables'Range loop
         Ensure_External_Value (Registry.Data.Scenario_Variables (J),
                                Registry.Data.Tree);
      end loop;
   end Create_Environment_Variables;

   ---------------------------------
   -- Reset_Environment_Variables --
   ---------------------------------

   procedure Reset_Environment_Variables (Registry : Project_Registry) is
   begin
      if Registry.Data.Scenario_Variables = null then
         Registry.Data.Scenario_Variables := new Scenario_Variable_Array'
           (Find_Scenario_Variables
              (Registry.Data.Root, Parse_Imported => True));
      end if;
   end Reset_Environment_Variables;

   ------------------------
   -- Scenario_Variables --
   ------------------------

   function Scenario_Variables (Registry : Project_Registry)
      return Projects.Scenario_Variable_Array is
   begin
      Reset_Environment_Variables (Registry);
      return Registry.Data.Scenario_Variables.all;
   end Scenario_Variables;

   ----------------------
   -- Get_Root_Project --
   ----------------------

   function Get_Root_Project (Registry : Project_Registry)
      return Projects.Project_Type is
   begin
      return Registry.Data.Root;
   end Get_Root_Project;

   -----------------------------
   -- Reset_Project_Name_Hash --
   -----------------------------

   procedure Reset_Project_Name_Hash
     (Registry : Project_Registry;
      Name     : Namet.Name_Id) is
   begin
      if Registry.Data /= null then
         Get_Name_String (Name);
         Remove (Registry.Data.Projects, Name_Buffer (1 .. Name_Len));
      end if;
   end Reset_Project_Name_Hash;

   ---------------------------
   -- Get_Project_From_Name --
   ---------------------------

   function Get_Project_From_Name
     (Registry : Project_Registry; Name : Namet.Name_Id) return Project_Type
   is
      P    : Project_Type;
      Node : Project_Node_Id;
   begin
      if Registry.Data = null then
         Trace (Me, "Get_Project_From_Name: Registry not initialized");
         return No_Project;

      else
         Get_Name_String (Name);
         P := Get (Registry.Data.Projects, Name_Buffer (1 .. Name_Len));

         if P = No_Project then
            Node := Prj.Tree.Tree_Private_Part.Projects_Htable.Get
              (Registry.Data.Tree.Projects_HT, Name).Node;

            if Node = Empty_Node then
               P := No_Project;
               Trace (Me, "Get_Project_From_Name: "
                      & Get_String (Name) & " wasn't found");

            else
               Create_From_Node
                 (P, Registry, Registry.Data.Tree,
                  Registry.Data.View_Tree, Node);
               Set (Registry.Data.Projects, Name_Buffer (1 .. Name_Len), P);
            end if;
         end if;

         return P;
      end if;
   end Get_Project_From_Name;

   ---------------------------
   -- Get_Project_From_File --
   ---------------------------

   function Get_Project_From_File
     (Registry          : Project_Registry;
      Source_Filename   : Virtual_File;
      Root_If_Not_Found : Boolean := True)
      return Project_Type
   is
      Id   : Source_Id;
      Path : Path_Name_Type;
      Prj  : Project_Id;
      Full : String := String
              (Full_Name
                (Source_Filename,
                 Normalize     => True,
                 Resolve_Links => Opt.Follow_Links_For_Files).all);

   begin
      --  Lookup in the project's Source_Paths_HT, rather than in
      --  Registry.Data.Sources, since the latter does not support duplicate
      --  base names. In Prj.Nmsc, names have been converted to lower case on
      --  case-insensitive file systems, so we need to do the same here.
      --  (Insertion is done in Check_File, where the Path passed in parameter
      --  comes from a call to Normalize_Pathname with the following args:
      --      Resolve_Links  => Opt.Follow_Links_For_Files
      --      Case_Sensitive => True
      --  So we use the normalized name in the above call to Full_Name for
      --  full compatibility between GPS and the project manager

      Osint.Canonical_Case_File_Name (Full);
      Path := Path_Name_Type (Name_Id'(Get_String (Full)));

      Id := Source_Paths_Htable.Get
        (Registry.Data.View_Tree.Source_Paths_HT, Path);

      if Id = No_Source then
         if Active (Me_Debug) then
            Trace (Me_Debug, "project not found for file " & Full
                   & " parameter was "
                   & Display_Full_Name (Source_Filename));
         end if;

         if Root_If_Not_Found then
            return Registry.Data.Root;
         else
            return No_Project;
         end if;
      end if;

      Prj := Id.Project;
      return Get_Project_From_Name (Registry, Prj.Name);
   end Get_Project_From_File;

   ---------------------------
   -- Get_Project_From_File --
   ---------------------------

   function Get_Project_From_File
     (Registry          : Project_Registry;
      Base_Name         : Filesystem_String;
      Root_If_Not_Found : Boolean := True) return Project_Type
   is
      P : constant Project_Type :=
            Get (Registry.Data.Sources, +Base_Name).Project;
   begin
      if P = No_Project and then Root_If_Not_Found then
         return Registry.Data.Root;
      end if;
      return P;
   end Get_Project_From_File;

   -----------------------------------
   -- Get_Source_And_Lang_From_File --
   -----------------------------------

   procedure Get_Source_And_Lang_From_File
     (Registry  : Project_Registry;
      Base_Name : Filesystem_String;
      Project   : out Project_Type;
      Source    : out Prj.Source_Id;
      Lang      : out Name_Id)
   is
      S : constant Source_File_Data := Get (Registry.Data.Sources, +Base_Name);
   begin
      if S = No_Source_File_Data then
         Project := No_Project;
         Source  := No_Source;
         Lang    := No_Name;
      else
         Project := S.Project;
         Source  := S.Source;
         Lang    := S.Lang;
      end if;
   end Get_Source_And_Lang_From_File;

   -----------------------------------------
   -- Get_Language_From_File_From_Project --
   -----------------------------------------

   function Get_Language_From_File_From_Project
     (Registry : Project_Registry; Source_Filename : Virtual_File)
      return Namet.Name_Id
   is
      function Get_File_Extension (Filename : String) return String;
      --  Returns the file extension removing any trailing version information

      ------------------------
      -- Get_File_Extension --
      ------------------------

      function Get_File_Extension (Filename : String) return String is
         Ext : constant String := File_Extension (Filename);
      begin
         if Ext'Length > 3
           and then Ext (Ext'Last) = ']'
           and then Ext (Ext'First .. Ext'First + 1) = ".["
         then
            return File_Extension
              (Filename (Filename'First .. Filename'Last - Ext'Length));
         else
            return Ext;
         end if;
      end Get_File_Extension;

      Base_Name : constant String :=
                    String (GNATCOLL.VFS.Base_Name (Source_Filename));
      S         : constant Source_File_Data :=
                    Get (Registry.Data.Sources, Base_Name);

   begin
      if S = No_Source_File_Data then
         --  This is most probably one of the runtime files.
         --  For now, we simply consider the standard GNAT extensions, although
         --  we should search in the list of registered languages
         --  (language_handlers-gps)

         declare
            Ext : constant String := Get_File_Extension (Base_Name);
         begin
            if Ext = ".ads" or else Ext = ".adb" then
               return Name_Ada;

            elsif Ext = "" then
               --  This is a file without extension like Makefile or
               --  ChangeLog for example. Use the filename to get the proper
               --  language for this file.

               return Languages_Htable.String_Hash_Table.Get
                 (Registry.Data.Extensions, To_Lower (Base_Name));

            else
               --  Try with the top-level project. This contains the default
               --  registered extensions when the languages were registered.
               --  At least, we might be able to display files that don't
               --  directly belong to a project with the appropriate
               --  highlighting.
               --  If there is no root project, this will use the default
               --  naming scheme

               return Languages_Htable.String_Hash_Table.Get
                 (Registry.Data.Extensions, Ext);
            end if;
         end;

      else
         return S.Lang;
      end if;
   end Get_Language_From_File_From_Project;

   -----------------------------------------
   -- Register_Default_Language_Extension --
   -----------------------------------------

   procedure Register_Default_Language_Extension
     (Registry            : Project_Registry;
      Language_Name       : String;
      Default_Spec_Suffix : String;
      Default_Body_Suffix : String)
   is
      Spec, Impl : String_Access;
      Spec_Suff  : String := Default_Spec_Suffix;
      Impl_Suff  : String := Default_Body_Suffix;
   begin
      --  GNAT doesn't allow empty suffixes, and will display an error when
      --  the view is recomputed, in that case. Therefore we substitute dummy
      --  empty suffixes instead

      if Default_Spec_Suffix = "" then
         Spec := new String'(Dummy_Suffix);
      else
         Canonical_Case_File_Name (Spec_Suff);
         Spec := new String'(Spec_Suff);
      end if;

      if Default_Body_Suffix = "" then
         Impl := new String'(Dummy_Suffix);
      else
         Canonical_Case_File_Name (Impl_Suff);
         Impl := new String'(Impl_Suff);
      end if;

      Registry.Data.Naming_Schemes := new Naming_Scheme_Record'
        (Language            => new String'(To_Lower (Language_Name)),
         Default_Spec_Suffix => Spec,
         Default_Body_Suffix => Impl,
         Next                => Registry.Data.Naming_Schemes);
   end Register_Default_Language_Extension;

   ----------------------------
   -- Add_Language_Extension --
   ----------------------------

   procedure Add_Language_Extension
     (Registry      : Project_Registry;
      Language_Name : String;
      Extension     : String)
   is
      Lang : constant Name_Id := Get_String (To_Lower (Language_Name));
      Ext  : String := Extension;
   begin
      Canonical_Case_File_Name (Ext);

      Languages_Htable.String_Hash_Table.Set
        (Registry.Data.Extensions, Ext, Lang);
   end Add_Language_Extension;

   -------------------------------
   -- Get_Registered_Extensions --
   -------------------------------

   function Get_Registered_Extensions
     (Registry      : Project_Registry;
      Language_Name : String) return GNAT.OS_Lib.Argument_List
   is
      Lang  : constant Name_Id := Get_String (To_Lower (Language_Name));
      Iter  : Languages_Htable.String_Hash_Table.Cursor;
      Name  : Name_Id;
      Count : Natural := 0;
   begin
      Get_First (Registry.Data.Extensions, Iter);

      loop
         Name := Get_Element (Iter);
         exit when Name = No_Name;

         if Name = Lang then
            Count := Count + 1;
         end if;

         Get_Next (Registry.Data.Extensions, Iter);
      end loop;

      declare
         Args : Argument_List (1 .. Count);
      begin
         Count := Args'First;
         Get_First (Registry.Data.Extensions, Iter);
         loop
            Name := Get_Element (Iter);
            exit when Name = No_Name;

            if Name = Lang then
               Args (Count) := new String'(Get_Key (Iter));
               Count := Count + 1;
            end if;

            Get_Next (Registry.Data.Extensions, Iter);
         end loop;

         return Args;
      end;
   end Get_Registered_Extensions;

   -------------
   -- Destroy --
   -------------

   procedure Destroy (Registry : in out Project_Registry) is
      procedure Unchecked_Free is new Ada.Unchecked_Deallocation
        (Project_Registry_Data, Project_Registry_Data_Access);
      Naming  : Naming_Scheme_Access;
      Naming2 : Naming_Scheme_Access;
   begin
      Unload_Project (Registry);

      if Registry.Data /= null then
         Naming := Registry.Data.Naming_Schemes;
         while Naming /= null loop
            Free (Naming.Language);
            Free (Naming.Default_Spec_Suffix);
            Free (Naming.Default_Body_Suffix);

            Naming2 := Naming.Next;
            Unchecked_Free (Naming);
            Naming := Naming2;
         end loop;

         Languages_Htable.String_Hash_Table.Reset (Registry.Data.Extensions);
         Unchecked_Free (Registry.Data.Predefined_Source_Path);
         Unchecked_Free (Registry.Data.Predefined_Object_Path);
         Free (Registry.Data.Tree);
         Free (Registry.Data.View_Tree);
         Unchecked_Free (Registry.Data);
      end if;
   end Destroy;

   ------------------
   -- Pretty_Print --
   ------------------

   procedure Pretty_Print
     (Project              : Project_Type;
      Increment            : Positive             := 3;
      Minimize_Empty_Lines : Boolean              := False;
      W_Char               : Prj.PP.Write_Char_Ap := null;
      W_Eol                : Prj.PP.Write_Eol_Ap  := null;
      W_Str                : Prj.PP.Write_Str_Ap  := null) is
   begin
      Pretty_Print
        (Project.Node,
         Project_Registry (Get_Registry (Project).all).Data.Tree,
         Increment,
         False,
         Minimize_Empty_Lines,
         W_Char, W_Eol, W_Str,
         Backward_Compatibility => Project_Backward_Compatibility,
         Id                     => Get_View (Project));
   end Pretty_Print;

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize is
   begin
      Namet.Initialize;
      Csets.Initialize;
      Snames.Initialize;

      Name_C_Plus_Plus := Get_String (Cpp_String);
      Any_Attribute_Name := Get_String (Any_Attribute);

      --  Disable verbose messages from project manager, not useful in GPS
      Opt.Quiet_Output := True;

      --  Use full path name so that the messages are sent to Locations view
      Opt.Full_Path_Name_For_Brief_Errors := True;
   end Initialize;

   --------------
   -- Finalize --
   --------------

   procedure Finalize is
   begin
      Namet.Finalize;
      Stringt.Initialize;

      --  ??? Should this be done every time we parse an ali file ?
      ALI.ALIs.Free;
      ALI.Units.Free;
      ALI.Withs.Free;
      ALI.Args.Free;
      ALI.Linker_Options.Free;
      ALI.Sdep.Free;
      ALI.Xref.Free;
   end Finalize;

   ------------
   -- Report --
   ------------

   overriding procedure Report
     (Handler : access Null_Error_Handler_Record;
      Msg     : String)
   is
      pragma Unreferenced (Handler, Msg);
   begin
      null;
   end Report;

   --------------------------------
   -- Get_Predefined_Source_Path --
   --------------------------------

   function Get_Predefined_Source_Path
     (Registry : Project_Registry) return File_Array is
   begin
      if Registry.Data.Predefined_Source_Path /= null then
         return Registry.Data.Predefined_Source_Path.all;
      else
         return (1 .. 0 => <>);
      end if;
   end Get_Predefined_Source_Path;

   --------------------------------
   -- Get_Predefined_Object_Path --
   --------------------------------

   function Get_Predefined_Object_Path
     (Registry : Project_Registry) return File_Array is
   begin
      if Registry.Data.Predefined_Object_Path /= null then
         return Registry.Data.Predefined_Object_Path.all;
      else
         return (1 .. 0 => <>);
      end if;
   end Get_Predefined_Object_Path;

   ---------------------------------
   -- Get_Predefined_Source_Files --
   ---------------------------------

   function Get_Predefined_Source_Files
     (Registry : Project_Registry) return GNATCOLL.VFS.File_Array is
   begin
      --  ??? A nicer way would be to implement this with a predefined project,
      --  and rely on the project parser to return the source
      --  files. Unfortunately, this doesn't work with the current
      --  implementation of this parser, since one cannot have two separate
      --  project hierarchies at the same time.

      if Registry.Data.Predefined_Source_Files = null then
         Registry.Data.Predefined_Source_Files := Read_Files_From_Dirs
           (Get_Predefined_Source_Path (Registry));
      end if;

      --  Make a copy of the result, so that we can keep a cache in the kernel

      if Registry.Data.Predefined_Source_Files = null then
         return Empty_File_Array;
      else
         return Registry.Data.Predefined_Source_Files.all;
      end if;
   end Get_Predefined_Source_Files;

   --------------------------------
   -- Set_Predefined_Source_Path --
   --------------------------------

   procedure Set_Predefined_Source_Path
     (Registry : in out Project_Registry; Path : File_Array) is
   begin
      Unchecked_Free (Registry.Data.Predefined_Source_Path);
      Registry.Data.Predefined_Source_Path := new File_Array'(Path);

      Unchecked_Free (Registry.Data.Predefined_Source_Files);

      --  ??? We used to initialize the caches with the runtime files, but I
      --  am not sure why this is needed since Get_Full_Path_From_File will do
      --  it just as well anyway, lazily. That speeds up start time in GPS.
      if False then
         Add_Runtime_Files (Registry, Path);
      end if;
   end Set_Predefined_Source_Path;

   --------------------------------
   -- Set_Predefined_Object_Path --
   --------------------------------

   procedure Set_Predefined_Object_Path
     (Registry : in out Project_Registry; Path : File_Array) is
   begin
      Unchecked_Free (Registry.Data.Predefined_Object_Path);
      Registry.Data.Predefined_Object_Path := new File_Array'(Path);
   end Set_Predefined_Object_Path;

   ---------------------------------
   -- Set_Predefined_Project_Path --
   ---------------------------------

   procedure Set_Predefined_Project_Path
     (Registry : in out Project_Registry; Path : File_Array) is
   begin
      Prj.Ext.Set_Project_Path (Registry.Data.Tree, +To_Path (Path));
   end Set_Predefined_Project_Path;

   -----------------------------
   -- Get_Full_Path_From_File --
   -----------------------------

   procedure Get_Full_Path_From_File
     (Registry                    : Project_Registry;
      Filename                    : Filesystem_String;
      Use_Source_Path             : Boolean;
      Use_Object_Path             : Boolean;
      Project                     : Project_Type := No_Project;
      Create_As_Base_If_Not_Found : Boolean := False;
      File                        : out Virtual_File)
   is
      Locale                 : Filesystem_String renames Filename;
      Project2, Real_Project : Project_Type;
      Path                   : Virtual_File;
      Iterator               : Imported_Project_Iterator;
      Info                   : Source_File_Data := No_Source_File_Data;
      In_Predefined          : Boolean := False;
      Project_Found          : Boolean := True;

   begin
      --  First check the cache, so that we always return the same instance
      --  of Virtual_File (thus saving allocation and system calls)

      if Use_Source_Path then
         Info := Get (Registry.Data.Sources, +Filename);

         if Info.Lang = Name_Error then
            --  Not found previously, we do not try again
            File := GNATCOLL.VFS.No_File;
            return;
         end if;

         if Info.File /= GNATCOLL.VFS.No_File then
            File := Info.File;
            return;
         end if;
      end if;

      --  Note: in this procedure, we test project with
      --  Get_View (..) /= Prj.No_Project
      --  rathen than by comparing directly with Projects.No_Project.
      --  This is slightly more efficient

      if Is_Absolute_Path (Filename) then
         File := Create (Normalize_Pathname (Locale, Resolve_Links => False));

      else
         --  If we are editing a project file, check in the loaded tree first
         --  (in case an old copy is kept somewhere in the source or object
         --  path)

         if Equal (File_Extension (Locale), Project_File_Extension)
           and then Get_View (Get_Root_Project (Registry)) /= Prj.No_Project
         then
            Iterator := Start (Get_Root_Project (Registry));

            loop
               Project2 := Current (Iterator);
               exit when Project2 = No_Project;

               if Equal (+Project_Name (Project2) & Project_File_Extension,
                         Filename)
               then
                  File := Project_Path (Project2);
                  return;
               end if;

               Next (Iterator);
            end loop;
         end if;

         --  Otherwise we have a source file

         Real_Project :=
           Get (Registry.Data.Sources, String (Filename)).Project;

         if Real_Project = No_Project then
            Project_Found := False;
            Real_Project := Registry.Data.Root;
         end if;

         if Project /= No_Project then
            Project2 := Project;
         else
            Project2 := Real_Project;
         end if;

         if Locale'Length > 0 then
            if Get_View (Project2) /= Prj.No_Project then
               if Use_Object_Path then
                  Path := Locate_Regular_File
                    (Locale, Object_Path (Project2, False, True));
               end if;
            end if;

            if Get_View (Get_Root_Project (Registry)) /= Prj.No_Project then
               if Path = GNATCOLL.VFS.No_File and then Use_Source_Path then
                  --  ??? Should not search again in the directories from
                  --  Project2

                  --  In general, we end up here when looking for runtime files
                  --  (since Use_Source_Path is specified, we are looking for
                  --  a source, and all those from the project are already
                  --  known). No need to search in current directory

                  Path := Locate_Regular_File
                    (Locale,
                     Get_Predefined_Source_Path (Registry));

                  if Path = GNATCOLL.VFS.No_File then
                     --  Check in current dir. We do it only later, so that we
                     --  do not have to use getcwd() when not needed
                     Path := Locate_Regular_File
                       (Locale, (1 => Get_Current_Dir));
                  end if;

                  if Path /= GNATCOLL.VFS.No_File then
                     In_Predefined := True;
                  end if;
               end if;

               if Path = GNATCOLL.VFS.No_File and then Use_Object_Path then
                  Path := Locate_Regular_File
                    (Locale,
                     Object_Path (Get_Root_Project (Registry), True, True)
                     & Get_Predefined_Object_Path (Registry));
               end if;
            end if;
         end if;

         if Path /= GNATCOLL.VFS.No_File then
            File := Path;

            --  If this is one of the source files, we cache the
            --  directory. This significantly speeds up the explorer. If
            --  this is not a source file, not need to cache it, it is a
            --  one-time request most probably.
            --  We do not cache anything if the project was forced, however
            --  since this wouldn't work with extended projects were sources
            --  can be duplicated.

            if In_Predefined then
               --  Make sure the file will be added in the cache. This is
               --  similar to what we used to do when the project is loaded
               --  (initialize the cache with files from the predefined
               --  path, assuming they are Ada), but done lazily

               if Info.Lang = No_Name then
                  Info.Lang := Get_Language_From_File_From_Project
                    (Registry, Path);
               end if;

               Info.File := Path;
               Info.Project := No_Project;
            end if;

            if Info /= No_Source_File_Data
              and then Project2 = Real_Project
            then
               Info.File := Path;
               Set (Registry.Data.Sources, String (Filename), Info);
            end if;

            return;

         elsif Project2 = Real_Project and then Project_Found then
            --  Still update the cache, to avoid further system calls to
            --  Locate_Regular_File. However, we shouldn't update the cache
            --  if the project was forced, since it might store incorrect
            --  information when we are using extended projects (with duplicate
            --  source files)
            if Use_Source_Path then
               Info := (Project => Project2,
                        File    => GNATCOLL.VFS.No_File,
                        Lang    => Name_Error,
                        Source  => No_Source);
               Set (Registry.Data.Sources, +Filename, Info);
            end if;
         end if;

         if Create_As_Base_If_Not_Found then
            File := Create (Full_Filename => Filename);
         else
            File := GNATCOLL.VFS.No_File;
         end if;
      end if;
   end Get_Full_Path_From_File;

   ----------------------------------
   -- Directory_Belongs_To_Project --
   ----------------------------------

   function Directory_Belongs_To_Project
     (Registry    : Project_Registry;
      Directory   : Filesystem_String;
      Direct_Only : Boolean := True) return Boolean
   is
      Belong : constant Directory_Dependency :=
                 Get (Registry.Data.Directories,
                      +Name_As_Directory (Directory));
   begin
      return Belong = Direct
        or else (not Direct_Only and then Belong = As_Parent);
   end Directory_Belongs_To_Project;

   ------------
   -- Create --
   ------------

   function Create
     (Name            : Filesystem_String;
      Registry        : Project_Registry'Class;
      Use_Source_Path : Boolean := True;
      Use_Object_Path : Boolean := True) return GNATCOLL.VFS.Virtual_File
   is
   begin
      if Is_Absolute_Path_Or_URL (Name) then
         return Create (Full_Filename => Name);

      else
         declare
            File : Virtual_File;
         begin
            Get_Full_Path_From_File
              (Registry        => Registry,
               Filename        => Name,
               Use_Source_Path => Use_Source_Path,
               Use_Object_Path => Use_Object_Path,
               File            => File);

            if File /= GNATCOLL.VFS.No_File then
               return File;
            end if;
         end;

         --  Else just open the relative paths. This is mostly intended
         --  for files opened from the command line.
         --  ??? To remove convertion to/from UTF8 we need a Normalize_Pathname
         --  which supports UTF-8.
         return Create
           (Full_Filename =>
              (Normalize_Pathname (Name,
                                   Resolve_Links => False)));
      end if;
   end Create;

   ---------------------------------
   -- Get_Predefined_Project_Path --
   ---------------------------------

   function Get_Predefined_Project_Path
     (Registry : Project_Registry) return File_Array is
   begin
      return From_Path (+Prj.Ext.Project_Path (Registry.Data.Tree));
   end Get_Predefined_Project_Path;

   ----------------------
   -- Set_Xrefs_Subdir --
   ----------------------

   procedure Set_Xrefs_Subdir
     (Registry : in out Project_Registry; Subdir : Filesystem_String)
   is
   begin
      if Registry.Data.Xrefs_Subdir /= null then
         GNAT.Strings.Free (Registry.Data.Xrefs_Subdir);
      end if;

      if Subdir'Length > 0 then
         Registry.Data.Xrefs_Subdir := new String'(+Subdir);
      end if;
   end Set_Xrefs_Subdir;

   ---------------------
   -- Set_Mode_Subdir --
   ---------------------

   procedure Set_Mode_Subdir
     (Registry : in out Project_Registry; Subdir : Filesystem_String)
   is
   begin
      if Prj.Subdirs /= null then
         if Prj.Subdirs.all /= +Subdir then
            Do_Subdirs_Cleanup (Registry);
         end if;

         Types.Free (Prj.Subdirs);
      end if;

      if Subdir'Length > 0 then
         Prj.Subdirs := new String'(+Subdir);
      end if;
   end Set_Mode_Subdir;

   ----------------------
   -- Get_Xrefs_Subdir --
   ----------------------

   function Get_Xrefs_Subdir
     (Registry : Project_Registry) return Filesystem_String is
   begin
      if Registry.Data.Xrefs_Subdir = null then
         return "";
      end if;

      return +Registry.Data.Xrefs_Subdir.all;
   end Get_Xrefs_Subdir;

   ---------------------
   -- Get_Mode_Subdir --
   ---------------------

   function Get_Mode_Subdir
     (Registry : Project_Registry) return Filesystem_String
   is
      pragma Unreferenced (Registry);
   begin
      if Prj.Subdirs = null then
         return "";
      end if;

      return +Prj.Subdirs.all;
   end Get_Mode_Subdir;

   ------------------------
   -- Do_Subdirs_Cleanup --
   ------------------------

   procedure Do_Subdirs_Cleanup (Registry : Project_Registry) is

      function Get_Paths return File_Array;
      --  Get the list of directories that potentially need cleanup

      ---------------
      -- Get_Paths --
      ---------------

      function Get_Paths return File_Array is
      begin
         if Registry.Data = null
           or else Get_View (Registry.Data.Root) = Prj.No_Project
         then
            return From_Path (+Prj.Subdirs.all);
         else
            declare
               Objs : constant String :=
                        Prj.Env.Ada_Objects_Path
                          (Get_View (Registry.Data.Root)).all;
            begin
               if Objs = "" then
                  return From_Path (+Prj.Subdirs.all);
               else
                  return From_Path (+Objs);
               end if;
            end;
         end if;
      end Get_Paths;

   begin
      --  Nothing to do if Prj.Subdirs is not set
      if Prj.Subdirs = null then
         return;
      end if;

      declare
         Objs    : constant File_Array := Get_Paths;
         Success : Boolean;
      begin
         for J in Objs'Range loop
            declare
               Dir : Virtual_File renames Objs (J);
            begin
               if Is_Directory (Dir) then
                  --  Remove emtpy directories (this call won't remove the dir
                  --  if files or subdirectories are in it.
                  Dir.Remove_Dir (Success => Success);
               end if;
            end;
         end loop;
      end;
   end Do_Subdirs_Cleanup;

   --------------
   -- Get_Tree --
   --------------

   function Get_Tree
     (Registry : Project_Registry) return Project_Node_Tree_Ref is
   begin
      return Registry.Data.Tree;
   end Get_Tree;

   ---------------
   -- Set_Value --
   ---------------

   procedure Set_Value
     (Registry : access Project_Registry;
      Var      : String;
      Value    : String) is
   begin
      if Registry.Data = null then
         --  We might be trying to set the environment before loading the
         --  project, which should be legal

         Reset (Registry.all, View_Only => False);
      end if;

      Prj.Ext.Add (Registry.Data.Tree, Var, Value);
   end Set_Value;

   ---------------
   -- Set_Value --
   ---------------

   procedure Set_Value
     (Registry : access Project_Registry;
      Var      : Scenario_Variable;
      Value    : String) is
   begin
      Set_Value (Registry, External_Reference_Of (Var), Value);
   end Set_Value;

   --------------
   -- Value_Of --
   --------------

   function Value_Of
     (Registry : Project_Registry;
      Var      : Scenario_Variable) return String is
   begin
      return Get_String
        (Prj.Ext.Value_Of
           (Registry.Data.Tree, Var.Name, With_Default => Var.Default));
   end Value_Of;

end Projects.Registry;

-----------------------------------------------------------------------
--                   GVD - The GNU Visual Debugger                   --
--                                                                   --
--                      Copyright (C) 2000-2005                      --
--                              AdaCore                              --
--                                                                   --
-- GVD is free  software;  you can redistribute it and/or modify  it --
-- under the terms of the GNU General Public License as published by --
-- the Free Software Foundation; either version 2 of the License, or --
-- (at your option) any later version.                               --
--                                                                   --
-- This program is  distributed in the hope that it will be  useful, --
-- but  WITHOUT ANY WARRANTY;  without even the  implied warranty of --
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU --
-- General Public License for more details. You should have received --
-- a copy of the GNU General Public License along with this library; --
-- if not,  write to the  Free Software Foundation, Inc.,  59 Temple --
-- Place - Suite 330, Boston, MA 02111-1307, USA.                    --
-----------------------------------------------------------------------

with GNAT.Regpat;           use GNAT.Regpat;
with Pixmaps_IDE;           use Pixmaps_IDE;
with Ada.Strings.Fixed;     use Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with String_Utils;          use String_Utils;
with C_Analyzer;            use C_Analyzer;

package body Language.C is

   Keywords_List : aliased Pattern_Matcher := Compile
     ("^(" & C_Keywords_Regexp & ")\W");
   --  for java: ("finally" "synchronized" "implements" "extends" "throws"
   --  "threadsafe" "transient" "native" "volatile"

   Subprogram_RE : aliased Pattern_Matcher :=
     Compile
       ("^\w+\s*"                         --  type specs; there can be no
        & "([\w_*]+\s+)?"                 --  more than 3 tokens, right?
        & "([\w_*]+\s+)?"
        & "([*&]+\s*)?"                   --  pointer
        & "(\(\*\s*)?([\w_]+[a-z][\w_]*)\s*\)?"
                                          --  subprogram name or access to subp
        & "(\s[\w_]+\s*\()?"              --  handling of macros, as in
                                          --  "void pa_exit PARAMS ((int))"
        & "\([^(]",
        Multiple_Lines);

   C_Explorer_Categories : constant Explorer_Categories :=
     (1 => (Category       => Cat_Function,
            Regexp         => Subprogram_RE'Access,
            Position_Index => 5,
            Icon           => subprogram_xpm'Access,
            Make_Entry     => null));

   C_Project_Fields : constant Project_Field_Array :=
     (1 => (Attribute_Name  => new String'("compiler_command"),
            Attribute_Index => new String'("c"),
            Description     => new String'("C compiler"),
            Values          => null,
            Editable        => True));

   --------------------
   -- Is_Simple_Type --
   --------------------

   function Is_Simple_Type
     (Lang : access C_Language; Str : String) return Boolean
   is
      pragma Unreferenced (Lang);
   begin
      return    Str = "int"
        or else Str = "char"
        or else Str = "float"
        or else Str = "double"
        or else Str = "long"
        or else Str = "short"

         --  "unsigned int", "unsigned char"
        or else (Str'Length >= 9
                 and then Str (Str'First .. Str'First + 8) = "unsigned ")

         --  "long int", "long unsigned int"
        or else (Str'Length >= 5
                 and then Str (Str'First .. Str'First + 4) = "long ")

         --  "short int", "short unsigned int"
        or else (Str'Length >= 6
                 and then Str (Str'First .. Str'First + 5) = "short ")

        or else Str = "void";
   end Is_Simple_Type;

   ----------------------
   -- Dereference_Name --
   ----------------------

   function Dereference_Name
     (Lang : access C_Language;
      Name : String) return String
   is
      pragma Unreferenced (Lang);
   begin
      return "(*" & Name & ")";
   end Dereference_Name;

   ---------------------
   -- Array_Item_Name --
   ---------------------

   function Array_Item_Name
     (Lang  : access C_Language;
      Name  : String;
      Index : String) return String
   is
      pragma Unreferenced (Lang);
   begin
      return Name & '[' & Index & ']';
   end Array_Item_Name;

   -----------------------
   -- Record_Field_Name --
   -----------------------

   function Record_Field_Name
     (Lang  : access C_Language;
      Name  : String;
      Field : String) return String
   is
      pragma Unreferenced (Lang);
   begin
      if Index (Name, "*") = 0 then
         return Name & '.' & Field;
      else
         --  Name is complex, protect it
         return '(' & Name & ")." & Field;
      end if;
   end Record_Field_Name;

   ----------------------
   -- Explorer_Regexps --
   ----------------------

   function Explorer_Regexps
     (Lang : access C_Language) return Explorer_Categories
   is
      pragma Unreferenced (Lang);
   begin
      return C_Explorer_Categories;
   end Explorer_Regexps;

   --------------
   -- Keywords --
   --------------

   function Keywords
     (Lang : access C_Language) return Pattern_Matcher_Access
   is
      pragma Unreferenced (Lang);
   begin
      return Keywords_List'Access;
   end Keywords;

   --------------------------
   -- Get_Language_Context --
   --------------------------

   C_Context             : aliased Language_Context :=
     (Comment_Start_Length          => 2,
      Comment_End_Length            => 2,
      Comment_Start                 => "/*",
      Comment_End                   => "*/",
      New_Line_Comment_Start        => new String'("//"),
      New_Line_Comment_Start_Regexp => null,
      String_Delimiter              => '"',
      Quote_Character               => '\',
      Constant_Character            => ''',
      Can_Indent                    => True,
      Syntax_Highlighting           => True,
      Case_Sensitive                => True);

   function Get_Language_Context
     (Lang : access C_Language) return Language_Context_Access
   is
      pragma Unreferenced (Lang);
   begin
      return C_Context'Access;
   end Get_Language_Context;

   ----------------------
   -- Parse_Constructs --
   ----------------------

   procedure Parse_Constructs
     (Lang   : access C_Language;
      Buffer : String;
      Result : out Construct_List)
   is
      pragma Unreferenced (Lang);
      Constructs : aliased Construct_List;
   begin
      Analyze_C_Source
        (Buffer,
         Default_Indent_Parameters,
         Format     => False,
         Constructs => Constructs'Unchecked_Access);
      Result := Constructs;
   end Parse_Constructs;

   --------------------
   -- Parse_Entities --
   --------------------

   procedure Parse_Entities
     (Lang     : access C_Language;
      Buffer   : String;
      Callback : Entity_Callback)
   is
      pragma Unreferenced (Lang);
      pragma Suppress (All_Checks);
      --  ??? For some reason we're sometimes getting a CE in this procedure
      --  with no apparent reason if checks are enabled.

   begin
      Analyze_C_Source
        (Buffer        => Buffer,
         Indent_Params => Default_Indent_Parameters,
         Format        => False,
         Callback      => Callback);
   end Parse_Entities;

   -------------------
   -- Format_Buffer --
   -------------------

   procedure Format_Buffer
     (Lang            : access C_Language;
      Buffer          : String;
      Replace         : Replace_Text_Callback;
      From, To        : Natural := 0;
      Indent_Params   : Indent_Parameters := Default_Indent_Parameters;
      Indent_Offset   : Natural := 0;
      Case_Exceptions : Case_Handling.Casing_Exceptions :=
        Case_Handling.No_Casing_Exception)
   is
      pragma Unreferenced (Lang, Case_Exceptions);
   begin
      Analyze_C_Source
        (Buffer,
         Indent_Params,
         True,
         From,
         To,
         Replace,
         Indent_Offset => Indent_Offset);
   end Format_Buffer;

   ------------------
   -- Comment_Line --
   ------------------

   function Comment_Line
     (Lang    : access C_Language;
      Line    : String;
      Comment : Boolean := True;
      Clean   : Boolean := False) return String
   is
      pragma Unreferenced (Lang);
      Index_Start : Natural;
      Index_Last  : Natural;
   begin
      if Line = "" then
         return "";
      end if;

      if Comment then
         --  Append "/* " at the beginning and " */" before the line end.

         declare
            New_Line : String (1 .. Line'Length + 3);
            Index    : Integer;
         begin
            Index := Line'First;

            while Index <= Line'Last
              and then Line (Index) /= ASCII.LF
              and then Line (Index) /= ASCII.CR
            loop
               Index := Index + 1;
            end loop;

            if Index = Line'First then
               return Line;
            end if;

            --  Insert the " */" before the end of line.

            if Index <= Line'Last then
               New_Line (1 .. Index - Line'First) :=
                 Line (Line'First .. Index - 1);

               New_Line (Index - Line'First + 1 .. Index - Line'First + 3) :=
                 " */";
               New_Line (Index - Line'First + 4 .. New_Line'Last) :=
                 Line (Index .. Line'Last);

               return "/* " & New_Line;
            else
               return "/* " & Line & " */";
            end if;
         end;
      else
         for Index in Line'First .. Line'Last - 1 loop
            if Line (Index .. Index + 1) = "//" then
               if Index + 3 <= Line'Last and then
                 Line (Index .. Index + 3) = "//  "
               then
                  if Clean then
                     Index_Start := Index + 4;
                     Skip_Blanks (Line, Index_Start);
                     return Line (Index_Start .. Line'Last);
                  end if;
                  return Line (Line'First .. Index - 1)
                    & Line (Index + 4 .. Line'Last);
               elsif Index + 2 <= Line'Last
                 and then Line (Index .. Index + 2) = "// "
               then
                  if Clean then
                     Index_Start := Index + 3;
                     Skip_Blanks (Line, Index_Start);
                     return Line (Index_Start .. Line'Last);
                  end if;
                  return Line (Line'First .. Index - 1)
                    & Line (Index + 3 .. Line'Last);
               else
                  if Clean then
                     Index_Start := Index + 2;
                     Skip_Blanks (Line, Index_Start);
                     return Line (Index_Start .. Line'Last);
                  end if;
                  return Line (Line'First .. Index - 1)
                    & Line (Index + 2 .. Line'Last);
               end if;
            elsif Line (Index .. Index + 1) = "/*" then
               Index_Last := Index;
               Skip_To_String (Line, Index_Last, "*/");

               if Index_Last < Line'Last
                 and then Line (Index_Last .. Index_Last + 1) = "*/"
               then
                  Index_Last := Index_Last - 1;
               end if;

               if Clean then
                  Index_Start := Index + 2;
                  Skip_Blanks (Line, Index_Start);
                  return Line (Index_Start .. Index_Last);
               end if;
               return Line (Line'First .. Index - 1)
                 & Line (Index + 3 .. Index_Last);
            end if;

            exit when not (Line (Index) = ' ' or else Line (Index) = ASCII.HT);
         end loop;

         Index_Last := Line'First;
         Skip_To_String (Line, Index_Last, "*/");
         if Index_Last < Line'Last
           and then Line (Index_Last .. Index_Last + 1) = "*/"
         then
            Index_Last := Index_Last - 1;
         end if;

         Index_Start := Line'First;
         if Clean then
            Skip_Blanks (Line, Index_Start);
         end if;

         return Line (Index_Start .. Index_Last);
      end if;
   end Comment_Line;

   -------------------
   -- Comment_Block --
   -------------------

   function Comment_Block
     (Lang    : access C_Language;
      Block   : String;
      Comment : Boolean := True;
      Clean   : Boolean := False) return String
   is
      Start_Of_Line : Natural := Block'First;
      End_Of_Line   : Natural := Line_End (Block, Start_Of_Line);

      New_Block     : Unbounded_String := To_Unbounded_String
        (Comment_Line
           (Lang,
            Block (Start_Of_Line .. End_Of_Line),
            Comment,
            Clean));

   begin
      loop
         Start_Of_Line := Next_Line (Block, Start_Of_Line);
         exit when Start_Of_Line = Block'Last;
         End_Of_Line := Line_End (Block, Start_Of_Line);

         Append (New_Block, ASCII.LF);
         Append
           (New_Block,
            Comment_Line
              (Lang,
               Block (Start_Of_Line .. End_Of_Line),
               Comment,
               Clean));
      end loop;

      return To_String (New_Block);
   end Comment_Block;

   ------------------------
   -- Get_Project_Fields --
   ------------------------

   function Get_Project_Fields
     (Lang : access C_Language) return Project_Field_Array
   is
      pragma Unreferenced (Lang);
   begin
      return C_Project_Fields;
   end Get_Project_Fields;

end Language.C;

with Ada.Unchecked_Deallocation;

package SN is
   --  Types and constant SN_Attributess specific to Source Navigator.

   type Table_Type is
      (BY, CL, COM, CON, COV, E, EC, F, FD, FIL, FR, FU, GV, SN_IN,
       IU, IV, LV, MA, MD, MI, SN_REM, SU, T, TO, UN);
   --  Source Navigator DB tables types

   type Symbol_Type is
     (Undef,   --  undefined symbol
      CL,      --  class/struct
      COM,     --  common block (Fortran)
      COV,     --  common variable (Fortrun)
      CON,     --  constant SN_Attributes
      E,       --  enum
      EC,      --  enum value
      FD,      --  function declaration
      FR,      --  friend
      FU,      --  function
      GV,      --  global variable
      SN_IN,   --  Inheritance
      IU,      --  include
      IV,      --  instance variable
      LV,      --  local variable
      MA,      --  macro
      MD,      --  method declaration
      MI,      --  method implementation
      SU,      --  sunroutine (Fortran)
      T,       --  typedef
      UN       --  union
      );

   Max_Src_Line_Length : constant Integer := 4096;
   --  Specifies the maximum line length for arbitrary source file.

   type Point is
      record
         Line : Integer;
         Column : Integer;
      end record;
   --  Position between symbols in source

   function "<" (P1, P2 : Point) return Boolean;
   --  LessThan operation in the terms

   type Segment is
      record
         First : Integer;
         Last : Integer;
      end record;
   Invalid_Segment : constant Segment := (-1, -1);

   function Length (s : Segment) return Integer;

   type String_Access is access String;
   procedure Free_String is
         new Ada.Unchecked_Deallocation (String, String_Access);

   function To_String (Buffer : String_Access; Seg : Segment) return String;
--   pragma Inline (To_String);

   type SN_Attributes is mod 2**32;

   --  symbol attributums
   SN_PRIVATE            : constant SN_Attributes := 16#000001#;
   SN_PROTECTED          : constant SN_Attributes := 16#000002#;
   SN_PUBLIC             : constant SN_Attributes := 16#000004#;
   SN_STATIC             : constant SN_Attributes := 16#000008#;
   SN_VIRTUAL            : constant SN_Attributes := 16#001000#;

   SN_ABSTRACT           : constant SN_Attributes := 16#000010#;
   SN_FINAL              : constant SN_Attributes := 16#000020#;
   SN_NATIVE             : constant SN_Attributes := 16#000040#;
   SN_SYNCHRONIZED       : constant SN_Attributes := 16#000080#;
   SN_VOLATILE           : constant SN_Attributes := 16#000100#;
   SN_TRANSIENT          : constant SN_Attributes := 16#000200#;
   SN_INTERFACE          : constant SN_Attributes := 16#000400#;
   SN_IMPLEMENTS         : constant SN_Attributes := 16#000800#;
   SN_INLINE             : constant SN_Attributes := 16#002000#;
   SN_CONSTRUCTOR        : constant SN_Attributes := 16#004000#;
   SN_DESTRUCTOR         : constant SN_Attributes := SN_CONSTRUCTOR;
   SN_PUREVIRTUAL        : constant SN_Attributes := 16#008000# or SN_VIRTUAL;
   SN_STRUCT_DEF         : constant SN_Attributes := 16#010000#;

   SN_OVERRIDE           : constant SN_Attributes := 16#20000#;
   SN_OVERLOADED         : constant SN_Attributes := 16#40000#;


   SN_TYPE_DEF           : constant SN_Attributes := 1;
   SN_CLASS_DEF          : constant SN_Attributes := 2;
   SN_MBR_FUNC_DEF       : constant SN_Attributes := 3;
   SN_MBR_VAR_DEF        : constant SN_Attributes := 4;
   SN_ENUM_DEF           : constant SN_Attributes := 5;
   SN_CONS_DEF           : constant SN_Attributes := 6;
   SN_MACRO_DEF          : constant SN_Attributes := 7;
   SN_FUNC_DEF           : constant SN_Attributes := 8;
   SN_SUBR_DEF           : constant SN_Attributes := 9;
   SN_GLOB_VAR_DEF       : constant SN_Attributes := 10;
   SN_COMMON_DEF         : constant SN_Attributes := 11;
   SN_COMMON_MBR_VAR_DEF : constant SN_Attributes := 12;
   SN_CLASS_INHERIT      : constant SN_Attributes := 13;
   SN_FILE_SYMBOLS       : constant SN_Attributes := 14;
   SN_CROSS_REF_BY       : constant SN_Attributes := 15;
   SN_CROSS_REF          : constant SN_Attributes := 16;
   SN_MBR_FUNC_DCL       : constant SN_Attributes := 17;
   SN_FUNC_DCL           : constant SN_Attributes := 18;
   SN_ENUM_CONST_DEF     : constant SN_Attributes := 19;
   SN_UNION_DEF          : constant SN_Attributes := 20;
   SN_FRIEND_DCL         : constant SN_Attributes := 21;
   SN_NAMESPACE_DEF      : constant SN_Attributes := 22;
   SN_EXCEPTION_DEF      : constant SN_Attributes := 23;
   SN_LOCAL_VAR_DEF      : constant SN_Attributes := 24;
   SN_VAR_DCL            : constant SN_Attributes := 25;
   SN_INCLUDE_DEF        : constant SN_Attributes := 26;
   SN_COMMENT_DEF        : constant SN_Attributes := 27;
   SN_CROSS_REF_CPP      : constant SN_Attributes := 28;
   SN_REF_UNDEFINED      : constant SN_Attributes := 29;
   SN_CROSS_REF_FILE     : constant SN_Attributes := 30;

   --  Cross reference values.
   SN_REF_TO_TYPEDEF     : constant SN_Attributes := SN_TYPE_DEF;
   SN_REF_TO_DEFINE      : constant SN_Attributes := SN_MACRO_DEF;
   SN_REF_TO_ENUM        : constant SN_Attributes := SN_ENUM_CONST_DEF;
   SN_REF_TO_STRUCT      : constant SN_Attributes := SN_STRUCT_DEF;
   SN_REF_TO_UNION       : constant SN_Attributes := SN_UNION_DEF;
   SN_REF_TO_CLASS       : constant SN_Attributes := SN_CLASS_DEF;
   SN_REF_TO_FUNCTION    : constant SN_Attributes := SN_FUNC_DEF;
   SN_REF_TO_MBR_FUNC    : constant SN_Attributes := SN_MBR_FUNC_DEF;
   SN_REF_TO_MBR_VAR     : constant SN_Attributes := SN_MBR_VAR_DEF;
   SN_REF_TO_COMM_VAR    : constant SN_Attributes := SN_COMMON_MBR_VAR_DEF;
   SN_REF_TO_CONSTANT    : constant SN_Attributes := SN_CONS_DEF;
   SN_REF_TO_SUBROUTINE  : constant SN_Attributes := SN_SUBR_DEF;
   SN_REF_TO_GLOB_VAR    : constant SN_Attributes := SN_GLOB_VAR_DEF;
   SN_REF_TO_LOCAL_VAR   : constant SN_Attributes := SN_LOCAL_VAR_DEF;
   --  SN_REF_TO_TEMPLATE    : constant SN_Attributes := SN_TEMPLATE_DEF;
   SN_REF_TO_NAMESPACE   : constant SN_Attributes := SN_NAMESPACE_DEF;
   SN_REF_TO_EXCEPTION   : constant SN_Attributes := SN_EXCEPTION_DEF;
   SN_REF_TO_LABEL       : constant SN_Attributes := SN_SUBR_DEF;

   SN_REF_SCOPE_LOCAL    : constant SN_Attributes := 0;
   SN_REF_SCOPE_GLOBAL   : constant SN_Attributes := 1;


   --  Variable references
   SN_REF_READ           : constant SN_Attributes := 0;
   SN_REF_WRITE          : constant SN_Attributes := 1;
   SN_REF_PASS           : constant SN_Attributes := 2;
   SN_REF_UNUSED         : constant SN_Attributes := 3;

end SN;

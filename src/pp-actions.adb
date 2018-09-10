with Ada.Characters.Handling; use Ada.Characters.Handling;
with Ada.Exceptions;
with Ada.Finalization;
with Ada.Strings.Fixed;
with Ada.Strings.UTF_Encoding;
with System.WCh_Cnv;
with System.WCh_Con;
with Text_IO, Ada.Wide_Text_IO;
with Pp.Buffers; use Pp.Buffers;
with Pp.Command_Lines; use Pp.Command_Lines;
with Pp.Error_Slocs; use Pp.Error_Slocs;
with Pp.Formatting; use Pp.Formatting;
with Pp.Formatting.Dictionaries;
with Pp.Scanner.Lines; use Pp.Scanner.Lines;

with Ada.Directories; use Ada.Directories;
with Interfaces; use type Interfaces.Unsigned_16;
with Unchecked_Deallocation;

with GNAT.Lock_Files;
with GNAT.OS_Lib; use GNAT.OS_Lib;

with Langkit_Support.Slocs; use Langkit_Support;
with Libadalang.Common; use Libadalang.Common;
with LAL_Extensions; use LAL_Extensions;

with Utils.Command_Lines.Common; use Utils.Command_Lines.Common;
with Utils.Dbg_Out;
with Utils.Formatted_Output;

with Utils_Debug; use Utils_Debug;
with Utils.Vectors;

with Utils.Symbols; use Utils.Symbols;
with Utils.Environment;
with Utils.Predefined_Symbols; use Utils.Predefined_Symbols;

package body Pp.Actions is

   use Utils.Char_Vectors.WChar_Vectors;

   function Image (X : Integer) return String
     renames Utils.String_Utilities.Image;

   pragma Warnings (Off);
   use Common_Flag_Switches, Common_String_Switches,
     Common_String_Seq_Switches, Common_Nat_Switches,
     Common_Boolean_Switches;

   use Pp_Flag_Switches,
     Pp_Boolean_Switches,
     Attribute_Casing_Switches,
     Keyword_Casing_Switches,
     Name_Casing_Switches,
     Enum_Casing_Switches,
     Type_Casing_Switches,
     Number_Casing_Switches,
     Pragma_Casing_Switches,
     Pp_String_Switches,
     Pp_Nat_Switches,
     Pp_String_Seq_Switches;
   pragma Warnings (On);

   File_Name_File_Name : String_Access;
   --  There is a "file name file"; this is its name. ASIS_Processing writes
   --  the output to a temp file, and Finalize moves the temp file to the
   --  actual output file. The file name file is used to pass the names of the
   --  temp and output files from ASIS_Processing to Finalize (both subunits of
   --  Utils.Source_Table.Processing).
   --
   --  ASIS_Processing is called once for each file, and it writes two lines to
   --  the file name file: the name of the temp file, and then the name of the
   --  output file. Finalize reads pairs of lines from the file name file, and
   --  moves temp --> output.
   --
   --  The reason for passing information via a file is that in
   --  Incremental_Mode, ASIS_Processing and Finalize are running in two
   --  different processes; the inner processes do ASIS_Processing, and need
   --  to pass those file names back to the outer process. The builder is in
   --  between inner and outer, and doesn't know how to cooperate in this
   --  dance.
   --
   --  The reason for doing all the renames at the end (after all
   --  ASIS_Processing is done) is again Incremental_Mode, specifically
   --  Replace_Modes. We don't want to replace the original input with the
   --  output during ASIS_Processing, because that would change timestamps and
   --  confuse the builder.
   --
   --  In Incremental_Mode, the File_Name_File_Name is constructed in the outer
   --  invocation (in Initialize), and passed down to the inner invocations via
   --  the command-line switch --file-name-file=. --file-name-file is not
   --  documented for users; it is for internal use only. In other modes, it is
   --  constructed in Initialize.
   --
   --  We use the file name file even in non-Incremental_Mode, even though it's
   --  not really necessary, just for uniformity/simplicity.
   --
   --  In Replace_Modes, we optimize by not overwriting the output (i.e. the
   --  input) if it didn't change. This is especially important in
   --  Incremental_Mode, because of the way the builder works: it will invoke
   --  gnatpp (in Mimic_gcc mode) on something.adb, which will pretty-print
   --  something.ads. If something.ads didn't need pretty-printing, we don't
   --  want to change its timestamp, causing real (code-generating) builds to
   --  do unnecessary recompiles.

   Null_Kind : constant Ada_Node_Kind_Type := Ada_Abort_Absent;
   --  ???We need a special value

   function Mimic_gcc (Cmd : Command_Line) return Boolean is
      (Arg (Cmd, Outer_Dir) /= null);

   ----------
   -- Init --
   ----------

   procedure Init (Tool : in out Pp_Tool; Cmd : Command_Line) is
      pragma Unreferenced (Tool);
      File_Name_File : Text_IO.File_Type;

      procedure Init_Pp_Off_And_On;
      --  Initialize Pp_Off_On_Delimiters

      procedure Init_Pp_Off_And_On is
      begin
         if Arg (Cmd, Pp_Off) /= null then
            pragma Assert (Arg (Cmd, Pp_Off).all /= "");
            Scanner.Pp_Off_On_Delimiters.Off := new W_Str'
              ("--" & To_Wide_String (Arg (Cmd, Pp_Off).all));
         end if;
         if Arg (Cmd, Pp_On) /= null then
            pragma Assert (Arg (Cmd, Pp_On).all /= "");
            Scanner.Pp_Off_On_Delimiters.On := new W_Str'
              ("--" & To_Wide_String (Arg (Cmd, Pp_On).all));
         end if;
      end Init_Pp_Off_And_On;

   --  Start of processing for Init

   begin
      --  Check that user did not specify --pp-off=X and --pp-on=X, where X = X

      if Arg (Cmd, Pp_Off) /= null and then Arg (Cmd, Pp_On) /= null then
         if Arg (Cmd, Pp_Off).all = Arg (Cmd, Pp_On).all then
            Text_IO.Put_Line -- Use Cmd_Error???
              (Text_IO.Standard_Error,
               "gnatpp: cannot specify --pp-off and --pp-on with same string");
            raise Command_Line_Error;
         end if;
      end if;

      Init_Pp_Off_And_On;

      --  ????Other checks from gnatpp/lal_ul-check_parameters.adb?

      pragma Assert (Environment.Initial_Dir = Current_Directory);
      if Mimic_gcc (Cmd) then
         pragma Assert (False);
         pragma Assert (Directories.Exists (File_Name_File_Name.all),
                        File_Name_File_Name.all & " not found");
      else
         File_Name_File_Name := new String'
           (Directories.Compose (Environment.Tool_Temp_Dir.all, "file_names"));

         --  Create an empty file name file, so ASIS_Processing can append to
         --  it. (Small annoyance: the file is not actually empty; it contains
         --  a single blank line, and Finalize has to work around that.)

         Text_IO.Create (File_Name_File,
                         Name => File_Name_File_Name.all);
         Text_IO.Close (File_Name_File);
      end if;

      Dictionaries.Scan_Dictionaries
        (Dictionary_File_Names => Arg (Cmd, Dictionary));
   end Init;

   -----------
   -- Final --
   -----------

   procedure Final (Tool : in out Pp_Tool; Cmd : Command_Line) is
      --  If this is the outer process of an incremental build, or it is a
      --  non-incremental build, we move all the temp files to the output
      --  files. We don't need any file locking here, because all the inner
      --  processes that were writing to the File_Name_File have finished.

      pragma Unreferenced (Tool);
      use Text_IO;
      File_Name_File : File_Type;
      Ignored : Boolean;
      Count : Natural := 0; -- number of files moved
   begin
      if Debug_Flag_1 then
         Utils.Dbg_Out.Output_Enabled := True;
         Utils.Symbols.Print_Statistics;
      end if;

      if not Mimic_gcc (Cmd)
      --  and then not Nothing_To_Do
      then
         begin
            Open (File_Name_File, In_File, Name => File_Name_File_Name.all);

            --  The File_Name_File contains an initial blank line, due to
            --  Text_IO weirdness, so we need to discard it.

            declare
               Ignore : constant String := Get_Line (File_Name_File);
            begin
               null;
            end;

            --  Read pairs of lines from the file name file, and do the moves.

            while not End_Of_File (File_Name_File) loop
               Count := Count + 1;
               declare
                  Temp_Output_Name : constant String :=
                    Get_Line (File_Name_File);
                  Output_Name : constant String := Get_Line (File_Name_File);
               begin
                  if False then
                     Put_Line ("mv " & Temp_Output_Name & " " & Output_Name);
                  end if;
                  Move_File
                    (Old_Name => Temp_Output_Name, New_Name => Output_Name);
               end;
            end loop;

            Close (File_Name_File);

            if not Debug_Flag_N then
               GNAT.OS_Lib.Delete_File (File_Name_File_Name.all, Ignored);
               --  No point in complaining on failure
            end if;
         exception
            when X : Move_Failure =>
               Cmd_Error (Ada.Exceptions.Exception_Message (X));
         end;
      end if;
   end Final;

   ---------------------
   -- Per_File_Action --
   ---------------------

   type Output_Modes is
   --  Defines the where and how gnatpp places the result source.
     (Pipe,
      --  Sends the output into Stderr.
      Output,
      --  Creates the file with the name specified in 'o' option. If the
      --  file with the given name already exists, does not erase it and gives
      --  up.
      Output_Force,
      --  Creates the file with the name specified in 'o' option. If the
      --  file with the given name already exists, erases the old file and
      --  replaces it with the pretty-printed source.
      Replace_Backup,
      --  Replaces the argument source with the pretty-printed source. The
      --  original source is stored in the file <arg_source>.npp. If the file
      --  with such a name already exists, gnatpp gives up.
      Replace_Force_Backup,
      --  Replaces the argument source with the pretty-printed source. The
      --  original source is stored in the file <arg_source>.npp. If the file
      --  with such a name already exists, gnatpp overrides it.
      Replace,
      --  Replaces the argument source with the pretty-printed source. The
      --  original source is not stored in any back-up file.
      Output_Directory);
      --  Put the result into <arg_source_simple_name> in directory Out_Dir.

   NPP_Suffix : constant String := ".npp";
   --  The suffixes for the file names for default result and backup copy
   --  files.

   subtype Create_Modes is Output_Modes with
     Predicate => Create_Modes in Output | Output_Force;
   pragma Unreferenced (Create_Modes);
   subtype Replace_Modes is Output_Modes with
     Predicate => Replace_Modes in Replace_Backup |
                                   Replace_Force_Backup |
                                   Replace;

   function Get_Output_Mode (Cmd : Command_Line) return Output_Modes;
   function Get_Output_Mode (Cmd : Command_Line) return Output_Modes is
      Result : Output_Modes := Replace;
   begin
      if Arg (Cmd, Output_Directory) /= null then
         Result := Output_Directory;
      end if;
      if Arg (Cmd, Pipe) then
         Result := Pipe;
      end if;
      if Arg (Cmd, Replace_Backup) then
         Result := Replace_Backup;
      end if;
      if Arg (Cmd, Replace_Force_Backup) then
         Result := Replace_Force_Backup;
      end if;
      if Arg (Cmd, Replace) then
         Result := Replace;
      end if;
      if Arg (Cmd, Output) /= null then
         Result := Output;
      end if;
      if Arg (Cmd, Output_Force) /= null then
         Result := Output_Force;
      end if;
      return Result;
   end Get_Output_Mode;

   ----------------

   use Line_Break_Vectors, Line_Break_Index_Vectors;
   use Tab_Vectors;
   Lines_Data : aliased Lines_Data_Rec;

   Cur_Indentation : Natural renames Lines_Data.Cur_Indentation;
   Next_Line_Break_Unique_Id : Modular
       renames Lines_Data.Next_Line_Break_Unique_Id;
   All_LB : Line_Break_Vector renames Lines_Data.All_LB;
   All_LBI : Line_Break_Index_Vector renames Lines_Data.All_LBI;
   Tabs : Tab_Vector renames Lines_Data.Tabs;
   Src_Tokns : Scanner.Tokn_Vec renames Lines_Data.Src_Tokns;
   New_Tokns : Scanner.Tokn_Vec renames Lines_Data.New_Tokns;
   Check_Whitespace : Boolean renames Lines_Data.Check_Whitespace;

   procedure Tree_To_Ada_2
     (Root      : Ada_Node;
      Cmd       : Utils.Command_Lines.Command_Line;
      Partial   : Boolean);
   --  Partial is True if we are not processing an entire file.

   --  Hard and soft line breaks:
   --
   --  A hard line break means a new-line WILL appear in the final output. A
   --  soft line break is a place where a new-line CAN appear; it will appear
   --  only if necessary to make lines short enough. Soft line breaks are
   --  prioritized: if there are several soft line breaks that can be used
   --  to shorten a given line, higher priority ones are chosen over lower
   --  priority ones. Normally, less nested ones are higher priority than
   --  more nested ones.

   type Str_Template is new W_Str;
   --  This is similar to Formatted_Output.Template, except instead of
   --  inserting strings into the template, it inserts subtrees. See
   --  Interpret_Template. The special character sequences are:
   --
   --      $ -- insert a hard line break
   --      $0 -- same as $, but doesn't affect comment indentation
   --           (see Line_Break.Affects_Comments)
   --      # -- insert a soft line break. May be followed by 1, 2, etc,
   --           to indicate additional nesting depth. Also +1, +2, etc
   --           (see below).
   --      { -- indent
   --      } -- outdent
   --      [ -- continuation-line indent
   --      ] -- continuation-line outdent
   --      * -- one space indent (see Spec_Alt template)
   --      _ -- one space outdent (see Spec_Alt template)
   --      ( -- insert a "(", and add "extra" indent by 1 character
   --      ???If a further indent ({ or [) is done without any
   --      intervening line break we should negate the effect of the
   --      "extra indent". See also Paren_Stack in PP.Formatting.
   --      Currently, we are assuming that "(" appears at the start
   --      of the line if indentation matters.
   --      ) -- insert a ")", and outdent the "extra"
   --      ^ -- tab based on following token. May be followed by 1, 2,
   --           etc, to indicate Index_In_Line.
   --      ` -- insertion point for next "^" tab. May be followed by 1, 2,
   --           etc, to indicate Index_In_Line.
   --      ! -- insert next required subtree
   --      ? -- insert next optional or list subtree
   --      ~ -- delimits arguments of ?
   --      !1, !2, !3, etc -- insert N'th required subtree
   --      ?1, ?2, ?3, etc -- insert N'th optional or list subtree
   --      / -- ignore next required subtree
   --  Other characters are inserted verbatim.
   --
   --  Note that we avoid conflicts with Ada tokens. If a special character
   --  sequence starts with a certain character, that character cannot start an
   --  Ada token that is different. The three "(", ")", and "/" are OK, because
   --  the special character sequence and the Ada token are identical. But we
   --  cannot, for example, have a special character sequence "%", because in
   --  Ada, "%" is the start of a string literal (albeit obsolescent).
   --
   --  All subtrees are required to be "used". If you don't want any output for
   --  a given subtree, then use / to ignore that subtree. Thus, all subtrees
   --  should be mentioned by one of: ! ? /.
   --
   --  ? takes three arguments, delimited by ~. If the subtree is a list, the
   --  first argument is placed before the list, the second in between list
   --  elements, and the third after the list, except if the list is empty,
   --  nothing is printed. If it's not a list, the first and third arguments
   --  are placed before and after, and the second must be empty, except if
   --  it's Null_Kind, nothing is printed.
   --
   --  Normally, the soft line breaks inserted by # have a priority based on
   --  the syntactic nesting depth. Less-nested breaks are enabled in favor of
   --  more deeply nested ones. However, if # is followed by a digit, that
   --  indicates an additional nesting depth not reflected in the syntax. For
   --  example, if we have "blah #blah #1blah", then the #1 is considered more
   --  nested than the #, so if the line is too long, we first enable the #,
   --  and only enable the #1 if the line is still too long.
   --  # may also be followed by "+" and a digit, as in "#+1".
   --  The difference is that for "#1", all subtrees start out deeper than the
   --  deepest of the outer ones, whereas for "#+1", the subtrees are just one
   --  level deeper than the outer tree. So for example, suppose we have a tree
   --  T at depth 5. Its immediate subtrees will normally be at depth 6.
   --  However, if there is a "#1" in the template for T, the immediate
   --  subtrees will be at depth 7. But if we change "#1" to "#+1", then the
   --  immediate subtrees will normally be at depth 6. Thus, "#+1" allows a
   --  given soft line break to be of equal depth to those of subtrees.
   --
   --  Examples:
   --  "!X!X!" -- inserts three subtrees, with "X" in between. "!1X!2X!3" --
   --  same as "!X!X!"
   --
   --  "?(~,~)~" -- a parenthesized comma-separated list
   --
   --  There is no way to escape the special characters, so for example, you
   --  can't print a literal $. So far, that wasn't needed, because those
   --  characters were deliberately chosen not to be part of Ada syntax. They
   --  can of course appear inside string literals and comments, but they're
   --  not needed in the templates.
   --
   --  Pairs of {}, [], and () must match and be properly nested.
   --
   --  The extra indentation for "(" is needed for parenthesized syntax, like
   --  this:
   --
   --      Do_Something
   --        (This,
   --         That);
   --        ^
   --        | Extra blank needed there.
   --
   --  Note: If you want to add new special characters, look at the case
   --  statement in Interpret_Template.

   type Str_Template_Ptr is access all Str_Template;

   --  ???Use some renamings for now, to ease the transition from ASIS to
   --  libadalang:
   subtype Ada_Tree_Kind is Ada_Node_Kind_Type;
   subtype Opt_ASIS_Elems is Ada_Node_Kind_Type;
   subtype Query_Index is Positive;
   subtype Query_Count is Natural;
   subtype Ada_Tree_Base is Ada_Node;
   subtype Ada_Tree is Ada_Node;
   subtype Ada_Tree_Array is Ada_Node_Array;
   function Is_Nil (T : Ada_Node'Class) return Boolean is
     (T.Is_Null);
   function Present (T : Ada_Node'Class) return Boolean is
     (not Is_Nil (T));
   function Subtree_Count
     (T : Ada_Node'Class) return Query_Count is
       (if Is_Nil (T) then 0 else Last_Child_Index (T));
   function Empty_Tree_Array return Ada_Node_Array is
     ((1 .. 0 => <>));
   function Subtrees (T : Ada_Node'Class) return Ada_Tree_Array is
     (if Is_Nil (T) then Empty_Tree_Array else Children (T));
   function Subtree
     (T : Ada_Node'Class; X : Query_Index) return Ada_Tree is
       (Child (T, X));

   function Template_For_Kind (Kind : Ada_Tree_Kind) return Str_Template_Ptr;

   function L (T1 : Str_Template) return Str_Template_Ptr;
   function L (T1, T2 : Str_Template) return Str_Template_Ptr;
   function L (T1, T2, T3 : Str_Template) return Str_Template_Ptr;
   function L (T1, T2, T3, T4 : Str_Template) return Str_Template_Ptr;
   function L (T1, T2, T3, T4, T5 : Str_Template) return Str_Template_Ptr;
   function L (T1, T2, T3, T4, T5, T6 : Str_Template) return Str_Template_Ptr;
   function L
     (T1, T2, T3, T4, T5, T6, T7 : Str_Template)
      return                       Str_Template_Ptr;
   --  All the L functions form a template by concatenating together a bunch of
   --  lines.

   Aspects : constant Str_Template := "?~~~";
   Aspects_Is : constant Str_Template := "?~~$~";
   --  The "_Is" template is used when the aspect specifications are followed
   --  by "is", which we want to put on a new line (if aspect specifications
   --  are present).

   function L (T1 : Str_Template) return Str_Template_Ptr is
   begin
      return new Str_Template'(T1);
   end L;

   function L (T1, T2 : Str_Template) return Str_Template_Ptr is
   begin
      return new Str_Template'(T1 & T2);
   end L;

   function L (T1, T2, T3 : Str_Template) return Str_Template_Ptr is
   begin
      return new Str_Template'(T1 & T2 & T3);
   end L;

   function L (T1, T2, T3, T4 : Str_Template) return Str_Template_Ptr is
   begin
      return new Str_Template'(T1 & T2 & T3 & T4);
   end L;

   function L (T1, T2, T3, T4, T5 : Str_Template) return Str_Template_Ptr is
   begin
      return new Str_Template'(T1 & T2 & T3 & T4 & T5);
   end L;

   function L
     (T1, T2, T3, T4, T5, T6 : Str_Template)
      return                   Str_Template_Ptr
   is
   begin
      return new Str_Template'(T1 & T2 & T3 & T4 & T5 & T6);
   end L;

   function L
     (T1, T2, T3, T4, T5, T6, T7 : Str_Template)
      return                       Str_Template_Ptr
   is
   begin
      return new Str_Template'(T1 & T2 & T3 & T4 & T5 & T6 & T7);
   end L;

   function Template_For_Kind (Kind : Ada_Tree_Kind) return Str_Template_Ptr is
   begin
      return
        (case Kind is
           when Ada_Discrete_Subtype_Name => null,
           when Ada_Unconstrained_Array_Index => null,
           when Ada_Contract_Case_Assoc => null,
           when Ada_Contract_Cases => null,
           when Ada_Multi_Dim_Array_Assoc => null,
           when Ada_Unconstrained_Array_Indices => null,
           when Ada_Error_Decl => null,
           when Ada_Error_Stmt => null,
            --  ???The above are not used

           when Ada_Ada_List => null,
           when Ada_Subp_Spec => null,
           when Ada_Aggregate_Assoc => null,

           when Ada_Constrained_Array_Indices =>
             L ("(?~,# ~~)"),
           when Ada_Aspect_Assoc =>
             L ("!? ^=> ~~~"),
           when Ada_At_Clause =>
             L ("for ! use at !"),
           when Ada_Attribute_Def_Clause | Ada_Enum_Rep_Clause =>
             L ("for ! use [!]"),
           when Ada_Record_Rep_Clause =>
             L ("for ! use record? at mod ~~;~$", "{?~;$~;$~}", "end record"),
           when Ada_Aspect_Spec =>
             L ("? with$" & "{~,$~}~"),
             --  ???We could try something like the following:
             --  "? with[#1 ~,#1 ~]~"
           when Ada_Component_Decl =>
             L ("?~,# ~~ ^: !? ^2:=[# ~~]~", Aspects),
           when Ada_Discriminant_Spec =>
             L ("?~,# ~~ ^: !? ^2:=[# ~~]~"),
           when Ada_Params => null,
           when Ada_Param_Spec => null,
           when Ada_Base_Package_Decl =>
             L ("package !#",
                Aspects_Is,
                " is$",
                "!",
                "!",
                "end !1/"),
           when Ada_Abstract_Subp_Decl =>
             L ("?~~ ~!", " is abstract", Aspects),
           when Ada_Expr_Function =>
             L ("?~~ ~!", " is[# !]", Aspects),
           when Ada_Null_Subp_Decl =>
             L ("?~~ ~!", " is null", Aspects),
           when Ada_Subp_Renaming_Decl =>
             L ("?~~ ~!!", Aspects),
           when Ada_Subp_Decl =>
             L ("?~~ ~!" & Aspects),
           when Ada_Subp_Body_Stub =>
             L ("?~~ ~! is separate" & Aspects),
           when Ada_Concrete_Formal_Subp_Decl =>
             L ("?~~ ~with !? is ~~~" & Aspects),
           when Ada_Abstract_Formal_Subp_Decl =>
             L ("?~~ ~with ! is abstract? ~~~" & Aspects),
           when Ada_Subp_Kind_Function =>
             L ("function"),
           when Ada_Subp_Kind_Procedure =>
             L ("procedure"),
           when Ada_Package_Body_Stub =>
             L ("package body ! is separate", Aspects),
           when Ada_Protected_Body_Stub =>
             L ("protected body ! is separate", Aspects),
           when Ada_Task_Body_Stub =>
             L ("task body ! is separate", Aspects),
           when Ada_Package_Body =>
             L ("package body !",
                Aspects_Is,
                " is$",
                "!",
                "!",
                "end !1/"),
           when Ada_Protected_Body =>
             L ("protected body !", Aspects_Is, " is$", "!", "end !1/"),
           when Ada_Subp_Body =>
             L ("?~~ ~!",
                Aspects_Is,
                "#+1 is$",
                "!",
                "!",
                "end !"),
               --  We increase the level of the # before " is", so it will be
               --  equal to that of the formal parameters, so if the "is" goes
               --  on a new line, the parameters will be split as well.
               --
               --  The last "!" refers to the name of the procedure, which
               --  replaces the F_End_Id (see Do_Subp_Decl). This is necessary
               --  because the name of the subprogram is buried in a subtree.

           when Ada_Task_Body =>
             L ("task body !",
                Aspects_Is,
                " is$",
                "!",
                "!",
                "end !1/"),
           when Ada_Entry_Decl =>
             L ("?~~ ~entry !", Aspects),
           when Ada_Entry_Spec =>
             L ("!?[# (~~)]~?~~~"),
           when Ada_Entry_Body =>
             L ("entry !?[# (~~)]~?~~~[# when !# is]$",
                --  ???Perhaps "# is]" should be "#+1 is]" or "# ]is".
                "!",
                "!",
                "end !1/"),
           when Ada_Enum_Literal_Decl =>
             L ("!"),
           when Ada_Exception_Decl =>
                 L ("?~,# ~~ ^: exception!", Aspects),
           when Ada_Generic_Package_Instantiation =>
             L ("package ! is new !?[# (~,# ~)]~", Aspects),
           when Ada_Generic_Subp_Instantiation =>
             L ("?~~ ~! ! is new !?[# (~,# ~)]~", Aspects),
           when Ada_Generic_Package_Decl =>
             L ("generic$",
                "!",
                "!"),
           when Ada_Generic_Formal_Part =>
             L ("{?~;$~;$~}"),
           when Ada_Generic_Formal_Obj_Decl |
               Ada_Generic_Formal_Subp_Decl | Ada_Generic_Formal_Type_Decl =>
             L ("!"),
           when Ada_Generic_Formal_Package =>
             L ("with !"),
           when Ada_Generic_Package_Renaming_Decl =>
             L ("generic package ! renames !", Aspects),
           when Ada_Generic_Subp_Renaming_Decl =>
             L ("generic ! ! renames !", Aspects),
           when Ada_Generic_Subp_Decl =>
             L ("generic$", "!", "!"),
           when Ada_Generic_Subp_Internal =>
             L ("!", Aspects),
           when Ada_Number_Decl =>
             L ("?~,# ~~ ^: constant ^2:=[# !]"),
           when Ada_Object_Decl |
               Ada_Extended_Return_Stmt_Object_Decl =>
             L ("?~,# ~~ ^:? ~~~? ~~~? ~~~ !? ^2:=[# ~~]~!", Aspects),
           when Ada_Package_Renaming_Decl =>
             L ("package !!", Aspects),
           when Ada_Single_Protected_Decl =>
             L ("protected !",
                Aspects_Is,
                " is? new ~ and ~ with~$",
                "!",
                "end !1"),
           when Ada_Protected_Type_Decl =>
             L ("protected type !!",
                Aspects_Is,
                " is? new ~ and ~ with~$",
                "!",
                "end !1"),
             --  ???The interfaces should be moved from
             --  Ada_Single_Protected_Decl and Ada_Protected_Type_Decl to
             --  Ada_Protected_Def.
           when Ada_Protected_Def =>
             L ("!$",
                "!$/"),
           when Ada_Single_Task_Decl =>
             L ("!"),
           when Ada_Single_Task_Type_Decl =>
             L ("task !!", Aspects_Is, "? is$~~~"),
           when Ada_Task_Type_Decl =>
             L ("task type !!",
                Aspects_Is,
                "? is~~~"),
           when Ada_Task_Def =>
             L ("? new ~ and ~ with~$",
                "!$",
                "!$",
                "end !"),
             --  The last "!" refers to the name of the task, which
             --  replaces the F_End_Id (see Do_Task_Def). This is necessary
             --  because the name of the task is buried in a subtree.

           when Ada_Enum_Type_Def =>
             L ("(?~,#1 ~~)"),
           when Ada_Type_Decl => null,
           when Ada_Incomplete_Type_Decl =>
             L ("type !!"), -- Aspects?
           when Ada_Incomplete_Tagged_Type_Decl =>
             L ("type !! is /tagged"),
               --  The "/" is for F_Has_Abstract, which is always
               --  Abstract_Absent.
           when Ada_Classwide_Type_Decl => null,
           when Ada_Subtype_Decl =>
             L ("subtype ! is[# !", Aspects, "]"),
           when Ada_Compilation_Unit => null,
           when Ada_Component_Def =>
             L ("?~~ ~?~~ ~!"),
               --  The second "?~~ ~" is for Has_Constant, which should never
               --  print anything.
           when Ada_Delta_Constraint =>
             L ("delta !? ~~~"),
           when Ada_Digits_Constraint =>
             L ("digits !? ~~~"),
           when Ada_Discriminant_Assoc => null,
           when Ada_Discriminant_Constraint | Ada_Index_Constraint =>
             L ("?[#(~,# ~)]~"),
           when Ada_Range_Constraint =>
             L ("!"),
           when Ada_Declarative_Part =>
             L ("?${~;$~};$$~"),
           when Ada_Private_Part =>
             L ("?$private${~;$~};$~"),
           when Ada_Public_Part =>
             L ("?{~;$~};$~"),
           when Ada_Elsif_Expr_Part =>
             L ("elsif[# !]# then[# !]"),
           when Ada_Entry_Index_Spec =>
             L ("for ! in[# !]"),
           when Ada_Exception_Handler =>
             L ("when[? ~~ :~ ?~ ^|# ~~] ^=>$", "{?~;$~;$~}"),
           when Ada_Explicit_Deref =>
             L ("!.all"),
           when Ada_Aggregate => null,
           when Ada_Null_Record_Aggregate =>
             L ("#(?~~ with #~" & "null record/)"),
           when Ada_Allocator =>
             L ("new? #(~~)~ !"),
           when Ada_Attribute_Ref =>
             L ("!'[#1!?# (~,# ~)~]"),
             --  ???This includes function calls to attributes, such as
             --  T'Max(X, Y), which isn't really right.
           when Ada_Update_Attribute_Ref =>
             L ("!'[#1!# !]"),
           when Ada_Bin_Op |  Ada_Relation_Op => null,
           when Ada_Call_Expr => null,
           when Ada_Case_Expr =>
             L ("case ! is[# ?#~,# ~~]"),
           when Ada_Case_Expr_Alternative =>
             L ("when[ ?~ |# ~~] ^=>[# !]"),
               --  ???Ada_Case_Stmt_Alternative has a "^" just before the "|"
           when Ada_Box_Expr =>
             L ("<>"),
           when Ada_If_Expr =>
             L ("if[#1 !]#1 then[#1 !]", "? #~ #~~", "?# else[ ~~]~"),
           when Ada_Membership_Expr =>
             L ("! ![# ?[#~ ^|# ~]~]"),
           when Ada_Dotted_Name =>
             L ("![#.!]"),
           when Ada_End_Name => L ("!"),
           when Ada_Defining_Name => L ("!"),
           when Ada_Char_Literal => null,
           when Ada_Identifier => null,
           when Ada_String_Literal => null,
           when Ada_Null_Literal =>
             L ("null"),
           when Ada_Real_Literal => null,
           when Ada_Int_Literal => null,
           when Ada_Qual_Expr =>
             L ("!'[#!]"),
               --  ???There are no parentheses here, because the subexpression
               --  is either a parenthesized expression or an aggregate.
           when Ada_Quantified_Expr =>
             L ("for ! ! ^=>[# !]"),
           when Ada_Raise_Expr =>
             L ("raise !?[# with ~~]~"),
           when Ada_Un_Op => null,
           when Ada_Handled_Stmts => null,
           when Ada_Library_Item =>
             L ("?~~ ~!"),
           when Ada_Null_Component_Decl =>
             L ("null"),
           when Ada_Others_Designator =>
             L ("others"),
           when Ada_Param_Assoc => null,
           when Ada_Pragma_Argument_Assoc => null,
           when Ada_Pragma_Node => null,
           when Ada_Component_Clause => null, -- ?
           when Ada_Renaming_Clause =>
             L ("? renames[# ~~]~"),
           when Ada_Select_Stmt =>
             L ("select",
                "!",
                "?else$", "{~;$~;$}~",
                "?then abort$", "{~;$~;$}~",
                "end select"),
           when Ada_Select_When_Part => null,
           when Ada_Accept_Stmt =>
             L ("accept !? #(~~)~?~~~"),
           when Ada_Accept_Stmt_With_Stmts =>
             L ("accept !? #(~~)~?~~~",
                "!",
                "end !1/"),
           when Ada_Null_Record_Def =>
             L ("null record/"),
             --  Null_Record_Def inherits F_Components from
             --  Base_Record_Def_Type, and it returns null.
           when Ada_Record_Def =>
             L ("record$", "!", "end record"),
           when Ada_Record_Type_Def =>
             L ("?~~ ~?~~ ~?~~ ~!"),
           when Ada_Component_List =>
             L ("{?~;$~;$~}", "{?~~;$~}"),
           when Ada_Variant =>
             L ("when[ ?~ ^|# ~~] ^=>$", "!"),
           when Ada_Case_Stmt_Alternative =>
             L ("when[ ?~ ^|# ~~] ^=>$", "{?~;$~;$~}"),
           when Ada_Case_Stmt | Ada_Variant_Part =>
             L ("case !# is$", "{!}", "end case"),
           when Ada_Extended_Return_Stmt =>
             L ("return[# !]",
                "!",
                "end return"),
           when Ada_If_Stmt =>
             L ("if[ !]# then$",
                "{?~;$~;$~}",
                "?~~~",
                "?else$",
                "{~;$~;$}~",
                "end if"),
           when Ada_Elsif_Stmt_Part =>
             L ("elsif[ !]# then$", "{?~;$~;$~}"),
           when Ada_Named_Stmt =>
             L ("! :$! !1"),
           when Ada_Named_Stmt_Decl =>
             L ("!"),
           when Ada_Begin_Block =>
             L ("!",
                "end/"),
           when Ada_Decl_Block =>
             L ("?declare$",
                "~~~",
                "!",
                "end/"),
               --  For Ada_Begin_Block and Ada_Decl_Block, the "begin" comes
               --  from Do_Handled_Stmts.
           when Ada_Loop_Stmt | Ada_For_Loop_Stmt | Ada_While_Loop_Stmt =>
             L ("?~~# ~loop$", "{?~;$~;$~}", "end loop/"),
           when Ada_For_Loop_Spec => null,
           when Ada_For_Loop_Var_Decl =>
             L ("!? : ~~~"),
           when Ada_While_Loop_Spec =>
             L ("while[ !]"),
           when Ada_Abort_Stmt =>
             L ("abort ?~, ~~"),
           when Ada_Assign_Stmt =>
             L ("! ^:=[# !]"),
           when Ada_Target_Name =>
             L ("@"),
           when Ada_Call_Stmt =>
             L ("!"),
           when Ada_Delay_Stmt =>
             L ("delay? ~~~ !"),
           when Ada_Exit_Stmt =>
             L ("exit? ~~~? when[ ~~]~"),
           when Ada_Goto_Stmt =>
             L ("goto !"),
           when Ada_Label => L ("<<!>>"),
           when Ada_Label_Decl => L ("!"),
           when Ada_Null_Stmt =>
             L ("null"),
           when Ada_Raise_Stmt =>
             L ("raise? ~~~?[# with ~~]~"),
           when Ada_Requeue_Stmt =>
             L ("requeue !? ~~~"),
           when Ada_Return_Stmt =>
             L ("return[? ~~~]"),
           when Ada_Terminate_Alternative =>
             L ("terminate"),
           when Ada_Subunit =>
             L ("separate (!)$", "!"),
           when Ada_Type_Access_Def =>
             L ("?~~ ~access? ~~~? ~~~ !"),
           when Ada_Array_Type_Def =>
             L ("array[# !] of !"),
           when Ada_Derived_Type_Def =>
             L ("?~~ ~?~~ ~?~~ ~new !? and[# ~ and# ~]~? with# ~~~? ~~~"),

           when Ada_Formal_Discrete_Type_Def =>
             L ("#(<>)"),
           when Ada_Interface_Type_Def =>
             L ("?~~ ~interface? and[# ~ and# ~]~"),
           when Ada_Mod_Int_Type_Def =>
             L ("mod !"),
           when Ada_Private_Type_Def =>
             L ("?~~ ~?~~ ~?~~ ~private"),
           when Ada_Range_Spec =>
             L ("range !"),
           when Ada_Decimal_Fixed_Point_Def =>
             L ("delta ! digits !? ~~~"),
           when Ada_Floating_Point_Def =>
             L ("digits !? ~~~"),
           when Ada_Ordinary_Fixed_Point_Def =>
             L ("delta !? ~~~"),

           when Ada_Signed_Int_Type_Def =>
             L ("!"),
           when Ada_Known_Discriminant_Part =>
             L ("?[# (~;# ~)]~#"),
           when Ada_Unknown_Discriminant_Part =>
             L (" #(<>)"),
           when Ada_Access_To_Subp_Def =>
             L ("?~~ ~access? ~~~ !"),
           when Ada_Anonymous_Type_Decl =>
             L ("//!", Aspects),
           when Ada_Synth_Anonymous_Type_Decl => null,
           when Ada_Anonymous_Type_Access_Def => null,
           when Ada_Subtype_Indication |
               Ada_Constrained_Subtype_Indication |
               Ada_Discrete_Subtype_Indication =>
             L ("?~~ ~!? ~~~"),
           when Ada_Anonymous_Type =>
             L ("!"),
           when Ada_Use_Package_Clause =>
             L ("use[# ?~,# ~~]"),
           when Ada_Use_Type_Clause =>
             L ("use? ~~~ type[# ?~,# ~~]"),
           when Ada_With_Clause =>
             L ("?~~ ~?~~ ~with ^?~, ~~"),
               --  Note: the tab ('^') is ignored for limited/private 'with's
               --  (see Append_Tab).

           when Ada_Paren_Expr =>
             L ("#(!)"),
           when Ada_Abort_Absent => null,
           when Ada_Abort_Present =>
             L ("with abort"),
           when Ada_Abstract_Absent => null,
           when Ada_Abstract_Present =>
             L ("abstract"),
           when Ada_Aliased_Absent => null,
           when Ada_Aliased_Present =>
             L ("aliased"),
           when Ada_All_Absent => null,
           when Ada_All_Present =>
             L ("all"),
           when Ada_Constant_Absent => null,
           when Ada_Constant_Present =>
             L ("constant"),
           when Ada_Mode_Default => null,
           when Ada_Mode_In =>
             L ("in"),
           when Ada_Mode_In_Out =>
             L ("in out"),
           when Ada_Mode_Out =>
             L ("out"),
           when Ada_Interface_Kind_Limited =>
             L ("limited"),
           when Ada_Interface_Kind_Protected =>
             L ("protected"),
           when Ada_Interface_Kind_Synchronized =>
             L ("synchronized"),
           when Ada_Interface_Kind_Task =>
             L ("task"),
           when Ada_Iter_Type_In =>
             L ("in"),
           when Ada_Iter_Type_Of =>
             L ("of"),
           when Ada_Limited_Absent => null,
           when Ada_Limited_Present =>
             L ("limited"),
           when Ada_Not_Null_Absent => null,
           when Ada_Not_Null_Present =>
             L ("not null"),

           when Ada_Op_In =>
             L ("in"),
           when Ada_Op_Not_In =>
             L ("not in"),

           when Ada_Op_And => null,
           when Ada_Op_Or => null,
           when Ada_Op_Or_Else => null,
           when Ada_Op_And_Then => null,
           when Ada_Op_Concat => null,
           when Ada_Op_Xor => null,
           when Ada_Op_Abs => null,
           when Ada_Op_Not => null,
           when Ada_Op_Pow => null,
           when Ada_Op_Mult => null,
           when Ada_Op_Div => null,
           when Ada_Op_Mod => null,
           when Ada_Op_Rem => null,
           when Ada_Op_Plus => null,
           when Ada_Op_Minus => null,
           when Ada_Op_Eq => null,
           when Ada_Op_Neq => null,
           when Ada_Op_Lt => null,
           when Ada_Op_Lte => null,
           when Ada_Op_Gt => null,
           when Ada_Op_Gte => null,
           when Ada_Op_Double_Dot => null,

           when Ada_Overriding_Not_Overriding =>
             L ("not overriding"),
           when Ada_Overriding_Overriding =>
             L ("overriding"),
           when Ada_Overriding_Unspecified => null,
           when Ada_Private_Absent => null,
           when Ada_Private_Present =>
             L ("private"),
           when Ada_Protected_Absent => null,
           when Ada_Protected_Present =>
             L ("protected"),
           when Ada_Quantifier_All =>
             L ("all"),
           when Ada_Quantifier_Some =>
             L ("some"),
           when Ada_Reverse_Absent => null,
           when Ada_Reverse_Present =>
             L ("reverse"),
           when Ada_Synchronized_Absent => null,
           when Ada_Synchronized_Present =>
             L ("synchronized"),
           when Ada_Tagged_Absent => null,
           when Ada_Tagged_Present =>
             L ("tagged"),
           when Ada_Until_Absent => null,
           when Ada_Until_Present =>
             L ("until"),
           when Ada_With_Private_Absent => null,
           when Ada_With_Private_Present =>
             L ("with private")
        ); -- end case
   end Template_For_Kind;

   Template_Tables_Initialized : Boolean := False;

   Str_Template_Table : array (Ada_Tree_Kind) of Str_Template_Ptr;

   type Instr_Kind is
     (Hard_Break,            -- "$"
      Hard_Break_No_Comment, -- "$0"
      Soft_Break,            -- "#" "#1", "#+1"
      Indent,                -- "{"
      Outdent,               -- "}"
      Continuation_Indent,   -- "["
      Continuation_Outdent,  -- "]"
      One_Space_Indent,      -- "*"
      One_Space_Outdent,     -- "_"
      '(',
      ')',
      Tab,                   -- "^", "^1"
      Tab_Insert_Point,      -- "`", "`1"
      Required_Subtree,      -- "!", "!1"
      Opt_Subtree_Or_List,   -- "?pre~between~post", "?1pre~between~post"
      Ignore_Subtree,        -- "/"
      Verbatim);

   type Instr_Array;
   type Instr_Array_Ptr is access all Instr_Array;

   type Tok_Template is record
      Instructions : Instr_Array_Ptr;

      Max_Nesting_Increment : Nesting_Level_Increment;
      --  If a digit occurs after '#', this is an additional "nesting
      --  increment" to be added to the nesting level when we recursively
      --  process the subtree. This is intended to allow some line breaks to
      --  have precedence over others. If no such digit occurs, the default is
      --  zero. This is the maximum such nesting increment in the template.
      --
      --  Note that "#+1" is ignored for Max_Nesting_Increment.
   end record;

   type Instr (Kind : Instr_Kind := Ignore_Subtree) is record
      --  "Instr" = one "instruction" in a Tok_Template.
      case Kind is
         when Hard_Break | Hard_Break_No_Comment => null;
         when Soft_Break =>
            Plus : Boolean;
            Level_Inc : Nesting_Level_Increment;
         when Indent | Outdent | Continuation_Indent | Continuation_Outdent
           | One_Space_Indent | One_Space_Outdent | '(' | ')' =>
            null;
         when Tab | Tab_Insert_Point =>
            Index_In_Line : Tab_Index_In_Line;
         when Required_Subtree | Opt_Subtree_Or_List =>
            Index : Query_Count; -- zero for "next"
            case Kind is
               when Opt_Subtree_Or_List =>
                  Pre, Between, Post : Tok_Template;
               when others => null;
            end case;
         when Ignore_Subtree => null;
         when Verbatim =>
            --  A token to be printed verbatim in the output. All we need is
            --  Kind and Text -- the Sloc and comment-specific fields of tokens
            --  are not used in templates.
            T_Kind : Scanner.Token_Kind;
            Text : Symbol;
      end case;
   end record;

   type Instr_Index is new Positive;
   type Instr_Array is
     array (Instr_Index range <>) of Instr;
   package Instr_Vectors is new Utils.Vectors
     (Instr_Index,
      Instr,
      Instr_Array);
   subtype Instr_Vector is Instr_Vectors.Vector;

   Tok_Template_Table : array (Ada_Tree_Kind) of Tok_Template;

   --  We have two representations for templates -- Str_Template is a sequence
   --  of characters, and Tok_Template is a sequence of tokens. We create the
   --  templates initially as Str_Templates, then convert them to Tok_Template,
   --  and use the Tok_Templates for further processing.

   function Back_To_Str_Templ (T : Tok_Template) return Str_Template;
   --  Convert back to Str_Template for assertion

   function Back_To_Str_Templ (T : Tok_Template) return Str_Template is
      Result : Bounded_W_Str (Max_Length => 80);

      function Im (Val : Integer) return W_Str is
        (From_UTF8 (Image (Val)));
   begin
      for X of T.Instructions.all loop
         case X.Kind is
            when Hard_Break => Append (Result, "$");
            when Hard_Break_No_Comment => Append (Result, "$0");

            when Soft_Break =>
               Append (Result, "#");
               if X.Plus then
                  Append (Result, "+");
               end if;
               if X.Level_Inc /= 0 then
                  Append (Result, Im (Integer (X.Level_Inc)));
               end if;

            when Indent => Append (Result, "{");
            when Outdent => Append (Result, "}");
            when Continuation_Indent => Append (Result, "[");
            when Continuation_Outdent => Append (Result, "]");
            when One_Space_Indent => Append (Result, "*");
            when One_Space_Outdent => Append (Result, "_");
            when '(' => Append (Result, "(");
            when ')' => Append (Result, ")");

            when Tab =>
               Append (Result, "^");
               if X.Index_In_Line /= 1 then
                  Append (Result, Im (Integer (X.Index_In_Line)));
               end if;

            when Tab_Insert_Point =>
               Append (Result, "`");
               if X.Index_In_Line /= 1 then
                  Append (Result, Im (Integer (X.Index_In_Line)));
               end if;

            when Required_Subtree =>
               Append (Result, "!");
               if X.Index /= 0 then
                  Append (Result, Im (Integer (X.Index)));
               end if;

            when Opt_Subtree_Or_List =>
               Append (Result, "?");
               if X.Index /= 0 then
                  Append (Result, Im (Integer (X.Index)));
               end if;
               Append (Result, W_Str (Back_To_Str_Templ (X.Pre)));
               Append (Result, "~");
               Append (Result, W_Str (Back_To_Str_Templ (X.Between)));
               Append (Result, "~");
               Append (Result, W_Str (Back_To_Str_Templ (X.Post)));
               Append (Result, "~");

            when Ignore_Subtree => Append (Result, "/");

            when Verbatim =>
               Append (Result, To_W_Str (X.Text));
         end case;
      end loop;

      return Str_Template (+Result);
   end Back_To_Str_Templ;

   function Fix_RM_Spacing
     (Cmd : Command_Line;
      T    : Str_Template;
      Kind : Ada_Tree_Kind := Null_Kind)
      return Str_Template;
   --  If the --RM-style-spacing switch was specified, modify the template as
   --  appropriate.

   function Fix_RM_Spacing
     (Cmd : Command_Line;
      T    : Str_Template;
      Kind : Ada_Tree_Kind := Null_Kind)
      return Str_Template
   is
   begin
      if not Arg (Cmd, Rm_Style_Spacing) then
         return T;
      end if;
      declare
         Result : Bounded_W_Str (Max_Length => T'Length * 2);
         X      : Natural := T'First;
         function C return W_Char is (T (X));
         function Match
           (S    : Str_Template)
            return Boolean is
           (T (X .. Natural'Min (T'Last, X + S'Length - 1)) = S);
           --  True if T contains S starting at X
      begin
         while X <= T'Last loop
            if Match (" (") or else Match (" #(") then
               X := X + 1; -- skip ' ' before '('
            elsif Match (" ^:") and then not Match (" ^:=") then
               X := X + 1; -- skip ' ' before ':'
            elsif Kind in Ada_Named_Stmt_Decl and then Match (" :") then
               X := X + 1; -- skip ' ' before ':' for statement name
            elsif Kind = Ada_Array_Type_Def and then Match (" !] of") then
               X := X + 1; -- skip ' ' before '('
            end if;

            Append (Result, C);
            X := X + 1;
         end loop;

         return Str_Template (To_String (Result));
      end;
   end Fix_RM_Spacing;

   function Replacements
     (Cmd : Command_Line; T : Str_Template) return Str_Template;

   function Replacements
     (Cmd : Command_Line; T : Str_Template) return Str_Template
   is
      Temp : W_Str_Access := new W_Str'(W_Str (T));
   begin
      --  Replacements for --no-separate-is

      if not Arg (Cmd, Separate_Is) then
         Temp := Replace_All (Temp, "# is", " is");
         Temp := Replace_All (Temp, "#+1 is", " is");
      end if;

      --  If the --no-end-id switch was given, do not insert names after "end"
      --  during the Convert_Tree_To_Ada pass. Instead, insert them during
      --  Insert_Comments_And_Blank_Lines, and only if they are present in the
      --  source.

      if not Arg (Cmd, End_Id) then
         Temp := Replace_All (Temp, "end !1", "end");
         Temp := Replace_All (Temp, "end !", "end/"); -- for Subp_Body
         Temp := Replace_All (Temp, "end?1 ~~~", "end");
         Temp := Replace_All (Temp, "end?2 ~~~", "end");
      end if;

      --  The --insert-blank-lines switch is mostly handled by
      --  Maybe_Blank_Line, but we need to handle "else" here,
      --  because it's not at the start of any construct.

      if Insert_Blank_Lines (Cmd) then
         Temp := Replace_All (Temp, "?else$", "?$else$");
      end if;

      return Result : constant Str_Template := Str_Template (Temp.all) do
         Free (Temp);
      end return;
   end Replacements;

   procedure Free is new Unchecked_Deallocation
     (Str_Template, Str_Template_Ptr);

   function Replace_One
     (Kind : Ada_Tree_Kind; From, To : W_Str) return Str_Template;
   procedure Replace_One (Kind : Ada_Tree_Kind; From, To : W_Str);
   --  Replace From with To in the template for Kind. The function returns
   --  the new template; the procedure replaces it in the table.
   procedure Replace_Tmp (Kind : Ada_Tree_Kind; From, To : W_Str);
   --  Same as Replace_One, but requires that the entire template be
   --  replaced.

   function Replace_One
     (Kind : Ada_Tree_Kind; From, To : W_Str) return Str_Template
   is
      pragma Assert (From /= To);
      Temp : Str_Template renames Str_Template_Table (Kind).all;
   begin
      return Str_Template (Must_Replace (W_Str (Temp), From, To));
   end Replace_One;

   procedure Replace_One (Kind : Ada_Tree_Kind; From, To : W_Str) is
      Temp : Str_Template_Ptr := Str_Template_Table (Kind);
   begin
      Str_Template_Table (Kind) :=
        new Str_Template'(Replace_One (Kind, From, To));
      Free (Temp);
   end Replace_One;

   procedure Replace_Tmp (Kind : Ada_Tree_Kind; From, To : W_Str) is
   begin
      pragma Assert (From = W_Str (Str_Template_Table (Kind).all));
      Replace_One (Kind, From, To);
   end Replace_Tmp;

   package Alternative_Templates is

      --  Some templates that are used instead of the ones in
      --  Str_Template_Table.

      type Alt_Templates is
        (Empty_Alt,
         Hard_Break_Alt,
         Semi_LB_Alt,
         Semi_LB_LB_Alt,
         Semi_Soft,
         Subtree_Alt,
         Comma_Soft,
         Pragma_Alt,
         Parameter_Specification_Alt,
         Extended_Return_Stmt_Alt,
         Vertical_Agg_Alt,
         Nonvertical_Agg_Alt,
         Obj_Decl_Vertical_Agg_Alt,
         Assign_Vertical_Agg_Alt,
         Pos_Notation_Assoc_Alt,
         Single_Name_Vertical_Assoc_Alt,
         Single_Name_Assoc_Alt,
         Multi_Name_Vertical_Assoc_Alt,
         Multi_Name_Assoc_Alt,
         Comp_Clause_Alt,
         Handled_Stmts_With_Begin_Alt,
         Handled_Stmts_With_Do_Alt,
         Depends_Hack_Alt,
         Un_Op_No_Space_Alt,
         Un_Op_Space_Alt,
         Dot_Dot_Wrong_Alt,
         Dot_Dot_For_Alt,
         Dot_Dot_Alt,
         Indent_Soft_Alt,
         Outdent_Alt,
         Soft_Alt,
         For_Loop_Spec_Stmt_Alt,
         For_Loop_Spec_Quant_Alt,
         Tab_2_Alt,
         Tab_3_Alt,
         AM_Tab_4_Alt,
         Not_AM_Default_Alt,
         Qualified_Aggr_Alt,
         Select_When_Alt,
         Select_Or_When_Alt,
         Call_Threshold_Alt,
         Call_Alt,
         Par_Threshold_Alt,
         Par_Alt,
         Spec_Threshold_Alt,
         Spec_Alt,
         Subtype_Ind_Index_Alt,
         Subtype_Ind_Alt,
         Record_Type_Decl_Split_Alt,
         Record_Type_Decl_Alt,
         Record_Type_Decl_Aspects_Alt,
         Access_To_Subp_Decl_Alt,
         Enum_Array_Decl_Alt,
         Type_Decl_Alt,
         Boxy_Constrained_Alt);

      Str_Alt_Table : array (Alt_Templates) of Str_Template_Ptr;

      subtype Subp_Decl_Body_Kind is Ada_Tree_Kind with
        Predicate => Subp_Decl_Body_Kind in
          Ada_Subp_Decl |
          Ada_Subp_Renaming_Decl |
          Ada_Access_To_Subp_Def |
          Ada_Entry_Decl |
          Ada_Formal_Subp_Decl |
          Ada_Generic_Subp_Decl |
          Ada_Subp_Body_Stub |
          Ada_Subp_Body |
          Ada_Abstract_Subp_Decl |
          Ada_Expr_Function |
          Ada_Null_Subp_Decl |
          Ada_Entry_Body;

      Str_Subp_Decl_With_Hard_Breaks_Alt_Table :
        array (Ada_Tree_Kind) of Str_Template_Ptr;

      Tok_Alt_Table : array (Alt_Templates) of Tok_Template;

      Tok_Subp_Decl_With_Hard_Breaks_Alt_Table :
        array (Ada_Tree_Kind) of Tok_Template;

   end Alternative_Templates;

   procedure Init_Template_Tables (Cmd : Command_Line);
   --  We call this to initialize the template tables the first time
   --  Tree_To_Ada is called, so that we can base the initialization
   --  in part on the command-line options.

   procedure Init_Template_Tables (Cmd : Command_Line) is
      use Alternative_Templates;

      function Subp_Decl_With_Hard_Breaks
        (Cmd : Command_Line; Kind : Subp_Decl_Body_Kind)
        return Str_Template;
      --  For implementing Par_Threshold. This replaces the soft line break
      --  between parameters with a hard line break. If Is_Function is True,
      --  put a hard line break before "return". Put a hard line break before
      --  "is", if any.

      procedure Init_Alternative_Templates;

      procedure Init_Tok_Templates;

      function Subp_Decl_With_Hard_Breaks
        (Cmd : Command_Line; Kind : Subp_Decl_Body_Kind)
        return Str_Template
      is
         Has_Is : constant Boolean :=
           (case Kind is
              when Ada_Subp_Decl |
                   Ada_Subp_Renaming_Decl |
                   Ada_Access_To_Subp_Def |
                   Ada_Entry_Decl |
                   Ada_Formal_Subp_Decl |
                   Ada_Generic_Subp_Decl => False,
              when Ada_Subp_Body_Stub |
                   Ada_Subp_Body |
                   Ada_Abstract_Subp_Decl |
                   Ada_Expr_Function |
                   Ada_Null_Subp_Decl |
                   Ada_Entry_Body => True);

         T : constant W_Str := W_Str (Str_Template_Table (Kind).all);
         T2 : constant W_Str :=
           (if Has_Is and then Arg (Cmd, Separate_Is)
             then Replace_All (T, "# is$", "$is$")
             else T);
         T3 : constant W_Str :=
           (if Has_Is and then Arg (Cmd, Separate_Is)
             then Replace_All (T2, "#+1 is$", "$is$")
             else T2);
      begin
         return Result : constant Str_Template := Str_Template (T3) do
            pragma Assert (True or else W_Str (Result) /= T); -- ???
         end return;
      end Subp_Decl_With_Hard_Breaks;

      procedure Init_Alternative_Templates is
         Stmts_And_Handlers : constant Str_Template :=
           "{~;$~;$}~" &
           "?exception$" &
           "{~$~}~";
      begin
         Str_Alt_Table :=
           (Empty_Alt => L (""),
            Hard_Break_Alt => L ("$"),
            Semi_LB_Alt => L (";$"),
            Semi_LB_LB_Alt => L (";$$"),
            Semi_Soft => L (";# "),
            Subtree_Alt => L ("!"),
            Comma_Soft => L (",# "),
            Pragma_Alt => L ("/?[ #(~,# ~)]~"),
            Parameter_Specification_Alt => L (" ^: "),
            Extended_Return_Stmt_Alt => L ("return !/"),
            Vertical_Agg_Alt => L ("(?~~ with #~?~,$~~)"),
            Nonvertical_Agg_Alt => L ("#(?~~ with #~?~,# ~~)"),
            Obj_Decl_Vertical_Agg_Alt =>
            L (Replace_One
                 (Ada_Object_Decl, From => ":=[# ~~]~!", To => ":=[$~~]~!")),
            Assign_Vertical_Agg_Alt =>
            L (Replace_One
                 (Ada_Assign_Stmt, From => ":=[# !]", To => ":=[$!]")),
            Pos_Notation_Assoc_Alt =>
              L ("?~~~!"), -- The "?~~~" generates nothing.
            Single_Name_Vertical_Assoc_Alt => L ("?~~ ^=>[$~!]"),
            Single_Name_Assoc_Alt => L ("?~~ ^=>[# ~!]"),
            Multi_Name_Vertical_Assoc_Alt => L ("?~ ^|#1 ~ ^=>[$~!]"),
            Multi_Name_Assoc_Alt => L ("?~ ^|#1 ~ ^=>[# ~!]"),
            Comp_Clause_Alt =>
            L ("! ^at `2! ^2range [#`3! ^3../[# `4!^4]]"),
             --  We need to ignore the ".." subtree, and put it explicitly in
             --  the template, because function Tab_Token checks for the ".".
            Handled_Stmts_With_Begin_Alt =>
            L ("?begin$" & Stmts_And_Handlers),
            Handled_Stmts_With_Do_Alt =>
            L ("# ?do$" & Stmts_And_Handlers),
            Depends_Hack_Alt => L ("?~~ ^=>~!"),
            Un_Op_No_Space_Alt => L ("/!"),
            Un_Op_Space_Alt => L ("/ !"),
            Dot_Dot_Wrong_Alt => L ("[[#! ../[# !]]]"),
                   --  This is wrong formatting, but gnatpp has an extra level
                   --  of indentation here. And it doesn't have "#1", which
                   --  actually would improve.???
            Dot_Dot_For_Alt => L ("[#! ../[#1 !]]"),
            Dot_Dot_Alt => L ("[#! ../[# !]]"),
            Indent_Soft_Alt => L ("[#"),
            Outdent_Alt => L ("]"),
            Soft_Alt => L ("#"),
            For_Loop_Spec_Stmt_Alt => L ("for ! !? ~~~ !"),
            For_Loop_Spec_Quant_Alt => L ("! !? ~~~ !#"),
            Tab_2_Alt => L ("^2"),
            Tab_3_Alt => L ("^3"),
            AM_Tab_4_Alt => L (" ^4:=[# !]"),
            Not_AM_Default_Alt => L (" :=[# !]"),
            Qualified_Aggr_Alt => L ("!'[#!]"),
             --  If the thing after the ' is an aggregate, we leave out the
             --  parentheses here, because the aggregate will insert them. We
             --  want T'(X, Y, Z), not T'((X, Y, Z)).
            Select_When_Alt =>
              L ("? when ~~ =>~$" & "{?~;$~;$~}"),
            Select_Or_When_Alt =>
            L ("or? when ~~ =>~$" & "{?~;$~;$~}"),
            Call_Threshold_Alt => L ("!?[$0(~,$0~)]~"),
             --  We use $0 instead of $ here, so that the indentation of these
             --  will not affect following comments.
            Call_Alt => L ("!?[# (~,#1 ~)]~"),
            Par_Threshold_Alt => L ("?[$(~;$~)]~"),
            Par_Alt => L ("?[# (~;#1 ~)]~"),
            Spec_Threshold_Alt => L ("!? ~~~?~~~?[$ return] ~~~"),
            Spec_Alt => L ("!? ~~~?~~~?[*#+2 return_] ~~~"),
            --  The above is the only place "one space in/outdent" is used (the
            --  "*" and "_" characters). This is to deal with something like:
            --
            --     function Some_Function
            --       (A_Parameter       : A_Parameter_Type;
            --        Another_Parameter : Another_Parameter_Type)
            --        return Result_Type;
            --       ^ Here we want the "return" indented one character
            --       | with respect to the "(", even though it is not
            --         inside the parentheses.

            Subtype_Ind_Index_Alt => L ("?~~ ~!?~~~"),
            Subtype_Ind_Alt => L ("?~~ ~!? ~~~"),
            Record_Type_Decl_Split_Alt =>
            L ("type !! is${!}" & Aspects),
            Record_Type_Decl_Alt => L ("type !! is !" & Aspects),
                      --  Otherwise, we could have a line break just before the
                      --  last semicolon.
            Record_Type_Decl_Aspects_Alt =>
            L ("type !! is !" & Aspects),
            Access_To_Subp_Decl_Alt => L ("type !! is !" & Aspects),
               --  gnatpp doesn't put a line break after "is" in this case.
            Enum_Array_Decl_Alt => L ("type !! is$[!]" & Aspects),
            Type_Decl_Alt => L ("type !! is[# !]" & Aspects),
            Boxy_Constrained_Alt => L ("(?~,# ~~)"));

         for Alt in Alt_Templates loop
            declare
               Temp : Str_Template_Ptr := Str_Alt_Table (Alt);
            begin
               Str_Alt_Table (Alt) :=
                 new Str_Template'(Fix_RM_Spacing (Cmd, Temp.all));
               Free (Temp);
            end;
         end loop;

         for K in Subp_Decl_Body_Kind loop
            Str_Subp_Decl_With_Hard_Breaks_Alt_Table (K) :=
              L (Fix_RM_Spacing (Cmd, Subp_Decl_With_Hard_Breaks (Cmd, K)));
         end loop;
      end Init_Alternative_Templates;

      procedure Init_Tok_Templates is
         use Scanner;
         function Compile_To_Instructions
           (Str : Str_Template_Ptr) return Tok_Template;
         --  Compile a Str_Template into a Tok_Template
         function Compile_Tokens
           (Cur  : in out Tokn_Cursor;
            Stop : Scanner.Token_Kind) return Tok_Template;
         --  Compile, starting at Cur, stopping when we see Stop. This is
         --  called by Compile_To_Instructions with Stop = End_Of_Input,
         --  and recursively by Parse_Instruction for '?' (Opt_Subtree_Or_List)
         --  with Stop = '~'. Moves Cur past the Stop token.

         function Parse_Instruction (Cur : in out Tokn_Cursor) return Instr;

         --  Note that Compile_Tokens and Parse_Instruction are functions with
         --  side effect (on Cur), so we need to take care not to call them in
         --  a context that allows arbitrary order of evaluation.

         function Parse_Instruction (Cur : in out Tokn_Cursor) return Instr is
            procedure Check_Between (Result : Instr);
            --  Assert that Between doesn't contain any indentation or similar,
            --  so we don't need special processing in Interpret_Template to
            --  extract it.

            procedure Check_Between (Result : Instr) is
            begin
               if Result.Kind = Opt_Subtree_Or_List then
                  for X of Result.Between.Instructions.all loop
                     pragma Assert
                       (X.Kind in Hard_Break | Hard_Break_No_Comment |
                          Soft_Break | Tab | Verbatim);
                  end loop;
               end if;
            end Check_Between;

            subtype Illegal_Chars is Character with Predicate =>
              Illegal_Chars in '~' | '"' | '\' | '%' | '0' .. '9';
            pragma Assert (Str (Text (Cur)).S (1) not in Illegal_Chars);

         --  Start of processing for Parse_Instruction

         begin
            return Result : Instr do
               case Kind (Cur) is
                  when '$' =>
                     Next (Cur);
                     if Kind (Cur) = Numeric_Literal then
                        pragma Assert (Text (Cur) = Intern ("0"));
                        Result := (Kind => Hard_Break_No_Comment);
                        Next (Cur);
                     else
                        Result := (Kind => Hard_Break);
                     end if;

                  when '#' =>
                     Next (Cur);
                     declare
                        Plus : constant Boolean := Kind (Cur) = '+';
                        Level_Inc : Nesting_Level_Increment;
                     begin
                        if Plus then
                           Next (Cur);
                        end if;

                        if Kind (Cur) = Numeric_Literal then
                           Level_Inc := Nesting_Level_Increment'Value
                             (Str (Text (Cur)).S);
                           Next (Cur);
                        else
                           Level_Inc := 0;
                        end if;

                        Result := (Soft_Break, Plus, Level_Inc);
                     end;

                  when '{' =>
                     Result := (Kind => Indent);
                     Next (Cur);
                  when '}' =>
                     Result := (Kind => Outdent);
                     Next (Cur);
                  when '[' =>
                     Result := (Kind => Continuation_Indent);
                     Next (Cur);
                  when ']' =>
                     Result := (Kind => Continuation_Outdent);
                     Next (Cur);
                  when '*' =>
                     Result := (Kind => One_Space_Indent);
                     Next (Cur);
                  when '_' =>
                     Result := (Kind => One_Space_Outdent);
                     Next (Cur);
                  when '(' =>
                     Result := (Kind => '(');
                     Next (Cur);
                  when ')' =>
                     Result := (Kind => ')');
                     Next (Cur);

                  when '^' =>
                     Next (Cur);
                     if Kind (Cur) = Numeric_Literal then
                        Result :=
                          (Tab, Index_In_Line =>
                                 Tab_Index_In_Line'Value (Str (Text (Cur)).S));
                        Next (Cur);
                     else
                        Result := (Tab, Index_In_Line => 1);
                     end if;

                  when '`' =>
                     Next (Cur);
                     if Kind (Cur) = Numeric_Literal then
                        Result :=
                          (Tab_Insert_Point, Index_In_Line =>
                                 Tab_Index_In_Line'Value (Str (Text (Cur)).S));
                        Next (Cur);
                     else
                        Result := (Tab_Insert_Point, Index_In_Line => 1);
                     end if;

                  when '!' =>
                     Next (Cur);
                     if Kind (Cur) = Numeric_Literal then
                        Result :=
                          (Required_Subtree,
                           Index => Query_Count'Value (Str (Text (Cur)).S));
                        Next (Cur);
                     else
                        Result := (Required_Subtree, Index => 0);
                     end if;

                  when '?' =>
                     Next (Cur);
                     declare
                        Index : Query_Count := 0;
                     begin
                        if Kind (Cur) = Numeric_Literal then
                           Index := Query_Count'Value (Str (Text (Cur)).S);
                           Next (Cur);
                        end if;

                        declare
                           Pre : constant Tok_Template :=
                             Compile_Tokens (Cur, Stop => '~');
                           Between : constant Tok_Template :=
                             Compile_Tokens (Cur, Stop => '~');
                           Post : constant Tok_Template :=
                             Compile_Tokens (Cur, Stop => '~');
                        begin
                           Result :=
                             (Opt_Subtree_Or_List, Index, Pre, Between, Post);
                        end;
                     end;

                  when '/' =>
                     Result := (Kind => Ignore_Subtree);
                     Next (Cur);

                  when others =>
                     for C of Str (Text (Cur)).S loop
                        pragma Assert (C not in Illegal_Chars);
                     end loop;

                     Result :=
                       (Kind => Verbatim,
                        T_Kind => Kind (Cur), Text => Text (Cur));
                     Next (Cur);
               end case;

               pragma Debug (Check_Between (Result));
            end return;
         end Parse_Instruction;

         function Compile_Tokens
           (Cur  : in out Tokn_Cursor;
            Stop : Scanner.Token_Kind) return Tok_Template
         is
            Instructions : Instr_Vector;
            use Instr_Vectors;
            Max_Nesting_Increment : Nesting_Level_Increment := 0;

            procedure Set_Max (Level_Inc : Nesting_Level_Increment);
            --  Set Max_Nesting_Increment to account for Level_Inc

            procedure Set_Max (Level_Inc : Nesting_Level_Increment) is
            begin
               Max_Nesting_Increment := Nesting_Level_Increment'Max
                 (Max_Nesting_Increment, Level_Inc);
            end Set_Max;
         begin
            while Kind (Cur) /= Stop loop
               declare
                  Inst : constant Instr := Parse_Instruction (Cur);
               begin
                  Append (Instructions, Inst);

                  if Inst.Kind = Soft_Break and then not Inst.Plus then
                     Set_Max (Inst.Level_Inc);
                  end if;

                  if Inst.Kind = Opt_Subtree_Or_List then
                     Set_Max (Inst.Pre.Max_Nesting_Increment);
                     Set_Max (Inst.Between.Max_Nesting_Increment);
                     Set_Max (Inst.Post.Max_Nesting_Increment);
                  end if;
               end;
            end loop;
            Next (Cur); -- skip the Stop token

            return (Instructions => new Instr_Array'(To_Array (Instructions)),
                    Max_Nesting_Increment => Max_Nesting_Increment);
         end Compile_Tokens;

         function Compile_To_Instructions
           (Str : Str_Template_Ptr) return Tok_Template
         is
            Tokens : aliased Tokn_Vec;
            Buf    : Buffer := String_To_Buffer (W_Str (Str.all));
            Ignored : Boolean := Get_Tokns
              (Buf, Tokens, Utils.Ada_Version,
               Lang => Template_Lang);
            Cur : Tokn_Cursor := First (Tokens'Unchecked_Access);
         begin
            pragma Assert (Kind (Cur) = Start_Of_Input);
            Next (Cur);
            return Result : constant Tok_Template :=
              Compile_Tokens (Cur, Stop => End_Of_Input)
            do
               pragma Assert (Back_To_Str_Templ (Result) = Str.all);
            end return;
         end Compile_To_Instructions;

      --  Start of processing for Init_Tok_Templates

      begin
         for K in Ada_Tree_Kind loop
            if Str_Template_Table (K) = null then
               pragma Assert (Tok_Template_Table (K).Instructions = null);
            else
               Tok_Template_Table (K) :=
                 Compile_To_Instructions (Str_Template_Table (K));
            end if;
         end loop;

         for Alt in Alt_Templates loop
            Tok_Alt_Table (Alt) :=
              Compile_To_Instructions (Str_Alt_Table (Alt));
         end loop;

         for K in Ada_Tree_Kind loop
            if Str_Subp_Decl_With_Hard_Breaks_Alt_Table (K) = null then
               pragma Assert
                 (Tok_Subp_Decl_With_Hard_Breaks_Alt_Table (K).Instructions =
                    null);
            else
               Tok_Subp_Decl_With_Hard_Breaks_Alt_Table (K) :=
                 Compile_To_Instructions
                   (Str_Subp_Decl_With_Hard_Breaks_Alt_Table (K));
            end if;
         end loop;
      end Init_Tok_Templates;

      --  Start of processing for Init_Template_Tables

   begin
      pragma Assert (not Template_Tables_Initialized);
      Template_Tables_Initialized := True;

      --  We can't initialize Str_Template_Table with an aggregate, because we
      --  refer to the Kind. The following case-within-loop construction may
      --  look odd, but it accomplishes two goals: the 'case' requires full
      --  coverage, so the items left null are done so explicitly, and the
      --  'for' provides the Kind value to each sub-case that needs it.
      --  The 'case' we're talking about is in Template_For_Kind.

      for Kind in Ada_Tree_Kind loop
         declare
            Temp : Str_Template_Ptr := Template_For_Kind (Kind);
         begin
            if Temp = null then
               Str_Template_Table (Kind) := null;
            else
               Str_Template_Table (Kind) :=
                 new Str_Template'
                   (Fix_RM_Spacing (Cmd, Replacements (Cmd, Temp.all), Kind));
               Free (Temp);
            end if;
         end;
      end loop;

      --  Some more-specific replacements

      --  For Separate_Loop_Then, we want a hard line break before
      --  "then" and "loop".

      if Arg (Cmd, Separate_Loop_Then) then
         Replace_One (Ada_If_Stmt, "# then$", "$then$");
         Replace_One (Ada_Elsif_Stmt_Part, "# then$", "$then$");
         Replace_One (Ada_Loop_Stmt, "?~~# ~loop$", "?~~$~loop$");
         Replace_One (Ada_For_Loop_Stmt, "?~~# ~loop$", "?~~$~loop$");
         Replace_One (Ada_While_Loop_Stmt, "?~~# ~loop$", "?~~$~loop$");

      --  For No_Separate_Loop_Then, we remove the soft line break
      --  before "then" and "loop".

      elsif Arg (Cmd, No_Separate_Loop_Then) then
         Replace_One (Ada_If_Stmt, "# then$", " then$");
         Replace_One (Ada_Elsif_Stmt_Part, "# then$", " then$");
         Replace_One (Ada_Loop_Stmt, "?~~# ~loop$", "?~~ ~loop$");
         Replace_One (Ada_For_Loop_Stmt, "?~~# ~loop$", "?~~ ~loop$");
         Replace_One (Ada_While_Loop_Stmt, "?~~# ~loop$", "?~~ ~loop$");
      end if;

      --  Replacements for Vertical_Enum_Types

      if Arg (Cmd, Vertical_Enum_Types) then
         Replace_Tmp (Ada_Enum_Type_Def, "(?~,#1 ~~)", "(?~,$~~)");
      end if;

      --  Replacements for Vertical_Array_Types

      if Arg (Cmd, Vertical_Array_Types) then
         Replace_Tmp (Ada_Array_Type_Def, "array[# !] of !", "array!$of !");
         Replace_Tmp
           (Ada_Constrained_Array_Indices,
            "(?~,# ~~)", "?{{ (~,# ~)}}~");
         --  Note the double indentation. It just happens that 3 more
         --  characters place us just after "array ". Perhaps we should
         --  use the Paren_Stack mechanism in PP.Formatting.
      end if;

      --  Replacements for Vertical_Named_Aggregates

      if Arg (Cmd, Vertical_Named_Aggregates) then
         Replace_Tmp (Ada_Enum_Rep_Clause, "for ! use [!]", "for ! use$[!]");
      end if;

      --  Replacements for Vertical_Case_Alternatives

      declare
         subtype When_Kinds is Ada_Node_Kind_Type with
           Predicate => When_Kinds in Ada_Case_Stmt_Alternative |
--  ???                                  Ada_Case_Expr_Alternative |
                                      Ada_Variant;
         --  Things that start with "when" that we want to treat
         --  alike here.
      begin
         if Arg (Cmd, Vertical_Case_Alternatives) then
            for X in When_Kinds loop
               Replace_One (X, "when[ ?~ ^|# ~~]", "when{ ?~$| ~~}");
               --  Perhaps this should be unconditional, not just for
               --  Vertical_Case_Alternatives.
            end loop;
            Replace_One (Ada_Case_Expr_Alternative,
                         "when[ ?~ |# ~~]", "when{ ?~$| ~~}");
         end if;
      end;

      --  Replacements for Split_Line_Before_Record

      if Arg (Cmd, Split_Line_Before_Record) then
         Replace_Tmp
           (Ada_Record_Rep_Clause,
            "for ! use record? at mod ~~;~${?~;$~;$~}end record",
            "for ! use${record? at mod ~~;~${?~;$~;$~}end record}");
      end if;

      --  Replacements for Indent_Named_Statements

      if Arg (Cmd, Indent_Named_Statements) then
         Replace_Tmp (Ada_Named_Stmt, "! :$! !1", "! :${! !1}");
      end if;

      Init_Alternative_Templates;

      --  Now do some validity checking on the templates

      for Kind in Ada_Tree_Kind loop
         declare
            T : constant Str_Template_Ptr := Str_Template_Table (Kind);
         begin
            if T /= null then
               declare
                  subtype Constrained_Query_Count is
                    Query_Count range 1 .. 9;
                  --  ???lal doesn't support reflection: Num_Queries (Kind);
                  Subtree_Count : Query_Count := 0;
               begin
                  for J in T'Range loop
                     case T (J) is
                        when '!' | '?' =>
                           if J < T'Last and then T (J + 1) in '1' .. '9' then
                              pragma Warnings (Off, "if it is invalid");
                              pragma Assert
                                (Query_Index (Char_To_Digit (T (J + 1))) in
                                   Constrained_Query_Count);
                              pragma Warnings (On, "if it is invalid");
                           else
                              Subtree_Count := Subtree_Count + 1;
                           end if;

                        --  ??? "{" is always preceded by "$" (not always
                        --  true for lalpp); we might want a short-hand for
                        --  "${".

                        when '{' =>
                           if Kind in Ada_Component_List |
                             Ada_Public_Part |
                             Ada_Generic_Formal_Part |
                             Ada_Array_Type_Def |
                             Ada_Constrained_Array_Indices |

                             Ada_Case_Stmt_Alternative |
                             Ada_Case_Expr_Alternative |
                             Ada_Variant
                           then
                              null;
                           else
                              pragma Assert (T (J - 1) = '$');
                           end if;

                        when others =>
                           null;
                     end case;
                  end loop;

                  if Subtree_Count /= Constrained_Query_Count'Last then
                     if False then -- ???See above.
                        raise Program_Error
                          with "Wrong Subtree_Count: " & Kind'Img;
                     end if;
                  end if;
               end;
            end if;
         end;
      end loop;

      Init_Tok_Templates;
   end Init_Template_Tables;

   --  Debugging printouts:
   --  See also Libadalang.Debug.
   pragma Warnings (Off);
   pragma Style_Checks (Off);
   procedure knd (X : Ada_Node) is
      use Utils.Dbg_Out;
   begin
      Utils.Dbg_Out.Output_Enabled := True;
      Put ("\1\n", Kind (X)'Img);
   end knd;

   procedure psloc (X : Ada_Node) is

      function Lines_String
        (Sloc_Range : Slocs.Source_Location_Range) return String is
         (Image (Integer (Sloc_Range.Start_Line)) & ": " &
          Image (Integer (Sloc_Range.End_Line)));

      use Utils.Dbg_Out;
   begin
      Utils.Dbg_Out.Output_Enabled := True;
      Put ("\1\n", Lines_String (Sloc_Range (X)));
   end psloc;

   procedure nn (X : Ada_Node) is
      use Utils.Dbg_Out;
   begin
      Utils.Dbg_Out.Output_Enabled := True;
      Put ("\1\n", (if Is_Nil (X) then "null" else Short_Image (X)));
   end nn;

   procedure ppp (X : Ada_Node) is
      use Utils.Dbg_Out;
   begin
      nn (X);
      if Present (X) then
         Print (X);
      end if;
   end ppp;

   procedure Put_Ada_Node_Array (X : Ada_Node_Array) is
      use Utils.Dbg_Out;
   begin
      for N of X loop
         nn (N);
         Put ("----------------\n");
      end loop;
   end Put_Ada_Node_Array;

   procedure Put_Child_Record (C : Child_Record) is
      use Utils.Dbg_Out;
   begin
      case C.Kind is
         when Child =>
            Put ("Child: \1\n", Short_Image (C.Node));
         when Trivia =>
            declare
               Trivia_Data : constant Token_Data_Type := Data (C.Trivia);
            begin
               Put ("Trivia: \1 ""\2"" \3\n",
                    Kind (Trivia_Data)'Img,
                    To_UTF8 (Text_To_W_Str (Text (C.Trivia))),
                    Slocs.Image (Sloc_Range (Trivia_Data)));
            end;
      end case;
   end Put_Child_Record;

   procedure Put_Children_Array (A : Children_Array) is
      use Utils.Dbg_Out;
   begin
      for I in A'Range loop
         Put ("\1: ", Image (I));
         Put_Child_Record (A (I));
      end loop;
   end Put_Children_Array;

   procedure Dump
     (Tool : in out Pp_Tool;
      Message : String := "")
   is
      pragma Unreferenced (Tool);
      use Utils.Formatted_Output;
   begin
      if Debug_Flag_V then
         Put ("\1\n", Message);
      end if;
   end Dump;

   procedure Put_Str_Templates is
      use Formatted_Output, Ada.Strings.Fixed;
   begin
      Put ("--  Templates:\n");

      for Kind in Ada_Tree_Kind loop
         if Str_Template_Table (Kind) /= null then
            declare
               T : constant String :=
                 To_UTF8 (W_Str (Str_Template_Table (Kind).all));
            begin
               Put ("--  \1 => \2", Capitalize (Kind'Img), """" & T & """");
               if Count (T, "[") /= Count (T, "]") then
                  Put ("    MISMATCHED [...]");
                  raise Program_Error;
               end if;
               if Count (T, "{") /= Count (T, "}") then
                  Put ("    MISMATCHED {...}");
                  raise Program_Error;
               end if;
               if Count (T, "(") /= Count (T, ")") then
                  Put ("    MISMATCHED (...)");
                  raise Program_Error;
               end if;
               Put ("\n");
            end;
         end if;
      end loop;
      Put ("--  End templates.\n");
   end Put_Str_Templates;
   pragma Style_Checks (On);
   pragma Warnings (On);

   function Is_Generic_Formal_Object_Decl (Tree : Ada_Tree) return Boolean;
   --  True if Tree is a generic formal object declaration

   function Is_Generic_Formal_Object_Decl (Tree : Ada_Tree) return Boolean is
      P : Ada_Tree := Parent (Tree);
      Formals : Ada_Tree;
   begin
      return Result : Boolean := False do
         if Tree.Kind = Ada_Object_Decl then
            if P.Kind = Ada_Ada_Node_List then
               P := Parent (P);
               if P.Kind in
                 Ada_Generic_Package_Decl | Ada_Generic_Subp_Decl
               then
                  if P.Kind = Ada_Generic_Package_Decl then
                     Formals :=
                       P.As_Generic_Package_Decl.F_Formal_Part.As_Ada_Node;
                  else
                     Formals :=
                       P.As_Generic_Subp_Decl.F_Formal_Part.As_Ada_Node;
                  end if;
                  for Formal of Formals.Children loop
                     if Tree = Formal then
                        Result := True;
                        exit;
                     end if;
                  end loop;
               end if;
            end if;
         end if;
      end return;
   end Is_Generic_Formal_Object_Decl;

   pragma Style_Checks ("M85");
   procedure Tree_To_Ada_2
     (Root      : Ada_Node;
      Cmd       : Utils.Command_Lines.Command_Line;
      Partial   : Boolean)
   is
      function Id_With_Casing
        (Id                       : W_Str;
         Kind                     : Opt_ASIS_Elems;
         Is_Predef                : Boolean)
         return                     W_Str;
      --  This handles casing of defining names and usage names, converting to
      --  the appropriate case based on command-line options. Kind is the kind of
      --  declaration denoted by Id, or an attribute, or nil. Is_Predef is True if
      --  Id denotes a predefined Ada or GNAT identifier.
      --
      --  This is called early (during Subtree_To_Ada). Casing of reserved words
      --  is handled later, in a separate pass (see Keyword_Casing), because they
      --  are not explicit in the tree, except that operator symbols are handled
      --  here. All of the Str_Templates have reserved words in lower case.
      --
      --  Id_With_Casing is used for Def_Names, Usage_Names and pragmas. For
      --  Def_Names, the Kind comes from the Symbol_Table, which only works
      --  because it's within one unit. That doesn't work for Usage_Names; we
      --  use the Decl_Kind attribute, which includes declared entities and
      --  attributes. For pragmas, we use the Kind of the pragma node.
      --
      --  Is_Predef is True if Id is a usage name that denotes a predefined
      --  entity. It is always False for defining names and pragmas.

      function Init_Use_Dictionary return Boolean;
      function Init_Use_Dictionary return Boolean is
      begin
         for D_Name of Arg (Cmd, Dictionary) loop
            if D_Name.all /= "-" then
               return True;
            end if;
         end loop;
         return False;
      end Init_Use_Dictionary;

      Use_Dictionary : constant Boolean := Init_Use_Dictionary;
      --  True if there are any dictionary files to use

      function Init_Use_Predefined_Casing return Boolean;
      function Init_Use_Predefined_Casing return Boolean is
      begin
         for D_Name of Arg (Cmd, Dictionary) loop
            if D_Name.all = "-" then
               return False;
            end if;
         end loop;
         return True;
      end Init_Use_Predefined_Casing;

      Use_Predefined_Casing : constant Boolean := Init_Use_Predefined_Casing;
      --  True if the -D- switch was NOT given

      Name_CPP_Class : aliased constant W_Str := "CPP_Class";
      Name_CPP_Constructor : aliased constant W_Str := "CPP_Constructor";
      Name_CPP_Virtual : aliased constant W_Str := "CPP_Virtual";
      Name_CPP_Vtable  : aliased constant W_Str := "CPP_Vtable ";
      Name_CPU : aliased constant W_Str := "CPU";
      Name_Persistent_BSS : aliased constant W_Str := "Persistent_BSS";
      Name_SPARK_Mode : aliased constant W_Str := "SPARK_Mode";
      Name_Use_VADS_Size : aliased constant W_Str := "Use_VADS_Size";
      Name_VADS_Size : aliased constant W_Str := "VADS_size";

      Special_Case_Names : constant
          array (Positive range <>) of access constant W_Str :=
        (Name_CPP_Class'Access,
         Name_CPP_Constructor'Access,
         Name_CPP_Virtual'Access,
         Name_CPP_Vtable 'Access,
         Name_CPU'Access,
         Name_Persistent_BSS'Access,
         Name_SPARK_Mode'Access,
         Name_Use_VADS_Size'Access,
         Name_VADS_Size'Access);

      function Id_With_Casing
        (Id                       : W_Str;
         Kind                     : Opt_ASIS_Elems;
         Is_Predef                : Boolean)
         return                     W_Str
      is
         pragma Assert (Id'First = 1);

         --  If it's a character literal, we want As_Declared -- it would be
         --  unfortunate to turn 'a' into 'A'. Operators go by keyword casing.
         --  Operator symbols (quoted) do so also, which seems wrong, but we're
         --  going to mimic the old gnatpp for now. Note that some reserved
         --  words can be an operator or an attribute name; hence the check for
         --  Ada_Attribute_Ref below. Predefined names use As_Declared unless
         --  Use_Predefined_Casing is turned off. For everything else, we use
         --  the appropriate option based on the Kind.

         Casing : constant PP_Casing :=
           (if Id (1) = ''' then As_Declared
            elsif Id (1) = '"' -- operator symbol
--              Kind not in Ada_Attribute_Ref | Ada_Update_Attribute_Ref
--              and then
--              (Id (1) = '"') -- operator symbol
--               or else Is_Reserved_Word (Id, Utils.Ada_Version)
--               or else Id = Name_And_Then
--               or else Id = Name_Or_Else)
            then
              PP_Keyword_Casing (Cmd)
            elsif Is_Predef and then Use_Predefined_Casing then
              As_Declared
            else
              (case Kind is
                 when Ada_Attribute_Ref | Ada_Update_Attribute_Ref =>
                   PP_Attribute_Casing (Cmd),
                 when Ada_Pragma_Node => PP_Pragma_Casing (Cmd),
                 when Ada_Enum_Literal_Decl =>
                   PP_Enum_Casing (Cmd),
                 when Ada_Type_Decl |
                     Ada_Incomplete_Type_Decl |
                     Ada_Incomplete_Tagged_Type_Decl |
                     Ada_Subtype_Decl |
                     Ada_Task_Type_Decl |
                     Ada_Task_Body |
                     Ada_Protected_Body |
                     Ada_Protected_Type_Decl |
                     Ada_Generic_Formal_Type_Decl =>
                   PP_Type_Casing (Cmd),
                 when Ada_Number_Decl => PP_Number_Casing (Cmd),
                 when Null_Kind =>
--                   (if PP_Name_Casing (Cmd) = As_Declared then Mixed
--                    else PP_Name_Casing (Cmd)),
                     PP_Name_Casing (Cmd),
                 when others => PP_Name_Casing (Cmd)));
         --  The Null_Kind case is for identifiers specific to pragmas
         --  and the like.

         use Dictionaries;
      begin
         if Use_Dictionary then
            return Result : W_Str := Id do
               Check_With_Dictionary (Ada_Name => Result, Casing => Casing);
            end return;
         else
            case Casing is
               when Lower_Case =>
                  return To_Lower (Id);

               when Upper_Case =>
                  return To_Upper (Id);

               when Mixed =>
                  if Kind in Ada_Attribute_Ref |
                    Ada_Update_Attribute_Ref |
                    Ada_Pragma_Node
                  then
                     --  Handle pragma and attribute names that are special cases
                     --  (some portion should be in ALL CAPS).

                     declare
                        Lower : constant W_Str := To_Lower (Id);
                     begin
                        for Special of Special_Case_Names loop
                           if Lower = To_Lower (Special.all) then
                              return Special.all;
                           end if;
                        end loop;
                     end;
                  end if;

                  return Capitalize (Id);

               when As_Declared =>
                  return Id;
            end case;
         end if;
      end Id_With_Casing;

      use Scanner;

      --  The following append a token to V, and also put the text in the
      --  output buffer. We should get rid of the textual output.

      procedure Append_And_Put (V : in out Tokn_Vec; X : Same_Text_Kind);
      procedure Append_And_Put
        (V : in out Tokn_Vec; X : Stored_Text_Kind; Tx : Symbol);
      --  Call Scanner.Append_Tokn, and also sends to the Out_Buf

      procedure Append_And_Put (V : in out Tokn_Vec; X : Ada_Op);

      procedure Append_And_Put (V : in out Tokn_Vec; X : Same_Text_Kind) is
      begin
         pragma Assert (X not in End_Of_Line);
         Append_Tokn (V, X);
      end Append_And_Put;

      procedure Append_And_Put
        (V : in out Tokn_Vec; X : Stored_Text_Kind; Tx : Symbol) is
      begin
         Append_Tokn (V, X, Tx);
      end Append_And_Put;

      procedure Append_And_Put (V : in out Tokn_Vec; X : Ada_Op) is
      begin
         case X is
            when Ada_Op_And => Append_And_Put (V, Res_And);
            when Ada_Op_Or => Append_And_Put (V, Res_Or);
            when Ada_Op_Or_Else =>
               Append_And_Put (V, Res_Or);
               Append_And_Put (V, Spaces, Name_Space);
               Append_And_Put (V, Res_Else);
            when Ada_Op_And_Then =>
               Append_And_Put (V, Res_And);
               Append_And_Put (V, Spaces, Name_Space);
               Append_And_Put (V, Res_Then);
            when Ada_Op_Concat => Append_And_Put (V, '&');
            when Ada_Op_Xor => Append_And_Put (V, Res_Xor);
            when Ada_Op_In => Append_And_Put (V, Res_In);
            when Ada_Op_Not_In =>
               Append_And_Put (V, Res_Not);
               Append_And_Put (V, Spaces, Name_Space);
               Append_And_Put (V, Res_In);
            when Ada_Op_Abs => Append_And_Put (V, Res_Abs);
            when Ada_Op_Not => Append_And_Put (V, Res_Not);
            when Ada_Op_Pow => Append_And_Put (V, Exp_Op);
            when Ada_Op_Mult => Append_And_Put (V, '*');
            when Ada_Op_Div => Append_And_Put (V, '/');
            when Ada_Op_Mod => Append_And_Put (V, Res_Mod);
            when Ada_Op_Rem => Append_And_Put (V, Res_Rem);
            when Ada_Op_Plus => Append_And_Put (V, '+');
            when Ada_Op_Minus => Append_And_Put (V, '-');
            when Ada_Op_Eq => Append_And_Put (V, '=');
            when Ada_Op_Neq => Append_And_Put (V, Not_Equal);
            when Ada_Op_Lt => Append_And_Put (V, '<');
            when Ada_Op_Lte => Append_And_Put (V, Less_Or_Equal);
            when Ada_Op_Gt => Append_And_Put (V, '>');
            when Ada_Op_Gte => Append_And_Put (V, Greater_Or_Equal);
            when Ada_Op_Double_Dot => Append_And_Put (V, Dot_Dot);
         end case;
      end Append_And_Put;

      procedure Indent (Amount : Integer);
      --  Indent by the given number of columns. Negative Amount for "outdent".

      procedure Indent (Amount : Integer) is
         pragma Assert
           (abs Amount in
              0 | 1 | PP_Indentation (Cmd) | PP_Indent_Continuation (Cmd) |
              Arg (Cmd, Initial_Indentation));
         Last_LBI : constant Line_Break_Index := All_LBI (Last (All_LBI));
         Last_LB : Line_Break renames All_LB (Last_LBI);
      begin
         Cur_Indentation := Cur_Indentation + Amount;

         if Last_LB.Hard and then Last_LB.Tok = Last (New_Tokns'Access) then
            Last_LB.Indentation := Cur_Indentation;
         end if;
      end Indent;

      procedure Append_Line_Break
        (Hard     : Boolean;
         Affects_Comments : Boolean;
         Level    : Nesting_Level;
         Kind     : Ada_Tree_Kind);

      function New_Level
        (Cur_Level     : Nesting_Level;
         TT            : Tok_Template)
         return          Nesting_Level;
      --  Compute a new nesting level for a subtree. This is usually one more than
      --  the current level, but we also add in Max_Nesting_Increment.

      procedure If_Stmt_Check_1;
      procedure If_Stmt_Check_2 (Level_Of_If : Nesting_Level);
      --  The above are for a special check related to if_statements, which comes
      --  in two parts. If_Stmt_Check_1 and _2 are called before and after
      --  calling Subtree_To_Ada on the condition of an 'if'.
      --
      --  The compiler style checks complain if "then" appears by itself on the
      --  line immediately following "if" (still true???), as in:
      --     if <condition>
      --     then
      --  where <condition> is just long enough to split the line before "then",
      --  but not long enough to be split itself. To avoid that, we make sure
      --  at least one line break in <condition> is at the same level as the one
      --  just before "then", thus ensuring that if the latter is enabled, some
      --  line break within <condition> will also be enabled. The same goes for
      --  "elsif".
      --
      --  Part _1 remembers the index of the first line break for the condition.
      --  Then the condition is walked, possibly inserting some line breaks. Part
      --  _2 then finds the minimum nested level (i.e. outermost), and patches
      --  that to equal the level of the 'if'. If there are no line breaks in the
      --  condition, but it is still long enough to force the "then" onto the next
      --  line, then there's not much we can do -- the style check will fail in
      --  that unlikely case.

      procedure Append_Line_Break
        (Hard     : Boolean;
         Affects_Comments : Boolean;
         Level    : Nesting_Level;
         Kind     : Ada_Tree_Kind)
      is
         pragma Unreferenced (Kind);
      begin
         --  If we see two line breaks in a row, we take the least indented one.

         if not Is_Empty (All_LBI) then
            declare
               Last_LBI : constant Line_Break_Index := All_LBI (Last (All_LBI));
               Last_LB : Line_Break renames All_LB (Last_LBI);
            begin
               if Hard and then
                 Scanner.Kind (Last (New_Tokns'Access)) = Enabled_LB_Token
               then
                  if Last_LB.Indentation > Cur_Indentation then
                     Last_LB.Indentation := Cur_Indentation;
                  end if;

                  if not Insert_Blank_Lines (Cmd) then
                     return;
                  end if;
               end if;
            end;
         end if;

         declare
            Tok : constant Scanner.Tokn_Cursor :=
                Next (Last (New_Tokns'Access));
         begin
            Append_Line_Break_Tokn
              (New_Tokns, Enabled => Hard, Index => Last_Index (All_LB) + 1);
            --  Note that the Line_Break_Token replaces the End_Of_Line token

            Append
              (All_LB,
               Line_Break'
                 (Tok         => Tok,
                  Tokn_Val    => Token_At_Cursor (Tok),
                  Hard        => Hard,
                  Affects_Comments => Affects_Comments,
                  Enabled     => Hard,
                  Level       => Level,
                  Indentation => Cur_Indentation,
                  Length      => <>,
      --            Kind        => Kind,
                  Internal_To_Comment => False,
                  UID         => Next_Line_Break_Unique_Id));
         end;
         Next_Line_Break_Unique_Id := Next_Line_Break_Unique_Id + 1;
         Append (All_LBI, Last_Index (All_LB));
      end Append_Line_Break;

      function New_Level
        (Cur_Level     : Nesting_Level;
         TT            : Tok_Template)
         return          Nesting_Level
      is
      begin
         return Cur_Level + TT.Max_Nesting_Increment + 1;
      end New_Level;

      First_If_Line_Break : Line_Break_Index_Index;
      --  Valid only between calls to If_Stmt_Check_1 and
      --  If_Stmt_Check_2. Set by _1 to 1 past the end of the table, which
      --  is where the next line break will be placed. Used by _2 to find the
      --  first line break (if any) belonging to the condition.

      procedure If_Stmt_Check_1 is
      begin
         First_If_Line_Break := Last_Index (All_LBI) + 1;
      end If_Stmt_Check_1;

      procedure If_Stmt_Check_2 (Level_Of_If : Nesting_Level) is
         Min : Nesting_Level := Nesting_Level'Last;
      begin
         --  Find the minimum level:
         for J in First_If_Line_Break .. Last_Index (All_LBI) loop
            Min := Nesting_Level'Min (Min, All_LB (All_LBI (J)).Level);
         end loop;

         --  Overwrite all line breaks at the minimum level to the level of the
         --  'if':
         for J in First_If_Line_Break .. Last_Index (All_LBI) loop
            if All_LB (All_LBI (J)).Level = Min then
               All_LB (All_LBI (J)).Level := Level_Of_If;
            end if;
         end loop;
      end If_Stmt_Check_2;

      procedure Subtree_To_Ada
        (Tree            : Ada_Tree;
         Cur_Level       : Nesting_Level;
         Index_In_Parent : Query_Index);
      --  We recursively walk the tree, and for most nodes, take the template
      --  from Str_Template_Table, and pass it to Interpret_Template. Some nodes
      --  need special casing, and bypass the Str_Template_Table. Subtree_To_Ada is
      --  directly recursive, and also mutually recursive with Interpret_Template.

      procedure Convert_Tree_To_Ada (Tree : Ada_Tree);
      --  Subtree_To_Ada with initial values for Cur_Level and Index_In_Parent,
      --  along with some fix-ups. In particular, we add a sentinel Line_Break
      --  at the beginning, and a sentinel Tab at the end.

      type Tree_Stack_Index is new Positive;
      subtype Tree_Stack_Count is
        Tree_Stack_Index'Base range 0 .. Tree_Stack_Index'Last;
      type Tree_Array is array (Tree_Stack_Index range <>) of Ada_Tree;
      package Tree_Stacks is new Utils.Vectors
        (Tree_Stack_Index,
         Ada_Tree,
         Tree_Array);
      use Tree_Stacks;
      --  use all type Tree_Stacks.Vector;

      Tree_Stack : Tree_Stacks.Vector;
      --  Stack of trees that we're in the process of traversing. Pushed and
      --  popped at the beginning and end of Subtree_To_Ada.

      function Ancestor_Tree
        (N : Tree_Stack_Count)
        return Ada_Tree;
      --  Returns the N'th ancestor of the current tree. Ancestor_Tree (0) is
      --  the current tree, Ancestor_Tree (1) is the parent of the current
      --  tree, Ancestor (2) is the grandparent of the current tree, and so
      --  on. Nil if the tree isn't deep enough.

      function Ancestor_Tree
        (N : Tree_Stack_Count)
        return Ada_Tree is
      begin
         if Last_Index (Tree_Stack) <= N then
            return No_Ada_Node;
         else
            return Tree_Stack (Last_Index (Tree_Stack) - N);
         end if;
      end Ancestor_Tree;

      function Parent_Tree return Ada_Tree is (Ancestor_Tree (1));

      pragma Warnings (Off); -- for debugging
      procedure Dump_Ancestors;
      procedure Dump_Ancestors is
         N : Tree_Stack_Count := 0;
         Tree : Ada_Tree;
         use Utils.Dbg_Out;
      begin
         Utils.Dbg_Out.Output_Enabled := True;
         Put ("Ancestors:\n");
         loop
            Tree := Ancestor_Tree (N);
            exit when Tree.Is_Null;
            Put ("\1\t\2\n", Image (Integer (N)), Short_Image (Tree));
            N := N + 1;
         end loop;
      end Dump_Ancestors;
      pragma Warnings (On);

      Label_Seen : Boolean := False;
      --  See the comments in Do_Label below for an explanation of this.

      procedure Subtree_To_Ada
        (Tree            : Ada_Tree;
         Cur_Level       : Nesting_Level;
         Index_In_Parent : Query_Index)
      is
         procedure Subtrees_To_Ada
           (Tree               : Ada_Tree;
            Pre, Between, Post : Tok_Template);

         procedure Interpret_Template
           (TT        : Tok_Template   := Tok_Template_Table (Tree.Kind);
            Subtrees  : Ada_Tree_Array := Pp.Actions.Subtrees (Tree);
            Cur_Level : Nesting_Level  := Subtree_To_Ada.Cur_Level;
            Kind      : Ada_Tree_Kind  := Tree.Kind);
         --  Interpret the template, printing literal characters, and recursively
         --  calling Subtree_To_Ada when the template calls for a subnode. Kind is
         --  for debugging.

         procedure Interpret_Alt_Template
           (Alt       : Alternative_Templates.Alt_Templates;
            Subtrees  : Ada_Tree_Array := Pp.Actions.Subtrees (Tree);
            Cur_Level : Nesting_Level  := Subtree_To_Ada.Cur_Level;
            Kind      : Ada_Tree_Kind  := Tree.Kind);
         --  Call Interpret_Template with one of the alternative templates

         procedure Interpret_Alt_Template
           (Alt       : Alternative_Templates.Alt_Templates;
            Subtrees  : Ada_Tree_Array := Pp.Actions.Subtrees (Tree);
            Cur_Level : Nesting_Level  := Subtree_To_Ada.Cur_Level;
            Kind      : Ada_Tree_Kind  := Tree.Kind) is
         begin
            Interpret_Template
              (Alternative_Templates.Tok_Alt_Table (Alt),
               Subtrees, Cur_Level, Kind);
         end Interpret_Alt_Template;

         procedure Append_Tab
           (Parent, Tree  : Ada_Tree_Base;
            Token_Text    : Symbol;
            Index_In_Line : Tab_Index_In_Line;
            Is_Insertion_Point : Boolean);
         --  Append a Tab_Rec onto Tabs.
         --
         --  Handling of "fake tabs":
         --  Fake tabs are used to deal with situations like this:
         --
         --     A_Long_Var_Name      : T          := 123;
         --     X                    : Ada_Long_Type_Name;
         --     A_Long_Constant_Name : constant T := 123;
         --
         --  where we wish to align the ":" and ":=" tokens. But the
         --  Insert_Alignment algorithm doesn't align things unless subsequent
         --  lines "match", which includes having the same number of tabs. But X
         --  has no ":=", so we add a fake tab so it will match the preceding and
         --  following lines.
         --
         --  Append_Tab inserts a fake tab after each ":" tab. If there is no
         --  ":=" following, the fake tab remains. If there IS a ":=", a real
         --  tab replaces the fake one.
         --
         --  Fake tabs initially have the same position as the preceding ":" tab.
         --  When Insert_Alignment calculates Max_Col, it ignores the fake ones,
         --  so they won't push anything further to the right. It sets the Col of
         --  the fake ones to Max_Col; hence Num_Blanks will be zero, so fake tabs
         --  won't insert any blanks.
         --
         --  Context clauses are handled in a similar manner:
         --
         --     with Ada.Characters.Handling; use Ada.Characters.Handling;
         --     with Ada.Exceptions;
         --     with Ada.Strings;             use Ada.Strings;

         procedure Append_Tab
           (Parent, Tree  : Ada_Tree_Base;
            Token_Text    : Symbol;
            Index_In_Line : Tab_Index_In_Line;
            Is_Insertion_Point : Boolean)
         is
            pragma Assert
              (Token_Text in Name_Tab_Insertion_Point |
                 Name_With | Name_Use | Name_Tab_In_Out | Name_Assign |
                 Name_Colon | Name_Arrow | Name_Bar | Name_At | Name_Range |
                 Name_Dot_Dot | Name_R_Sq);

            Pa              : Ada_Tree_Base := Parent;
            Tr              : Ada_Tree_Base := Tree;

            procedure Maybe_Replace_Fake_Tab;
            --  Replace a fake tab with a real one, if appropriate. In
            --  particular, if the last tab is fake, and the current one has
            --  the same Index_In_Line, Tree, and Parent, then the current one
            --  replaces the fake one. We don't physically delete the Tab_Rec
            --  from the table, nor the Tab_Token from the token stream; we
            --  just mark it as Deleted, so later phases know to ignore it.

            procedure Maybe_Replace_Fake_Tab is
            begin
               if Is_Empty (Tabs) then
                  return;
               end if;

               declare
                  Tb : Tab_Rec renames Last_Ptr (Tabs).all;
               begin
                  if Tb.Is_Fake
                    and then Tb.Index_In_Line = Index_In_Line
                    and then Tb.Tree = Tr
                    and then Tb.Parent = Pa
                  then
                     pragma Assert (Tb.Token = Token_Text);
                     pragma Assert
                       ((Token_Text = Name_Assign
                           and then Index_In_Line in 2 | 4)
                        or else
                          (Token_Text = Name_Use and then Index_In_Line = 2));
                     pragma Assert (not Is_Insertion_Point);
                     pragma Assert (not Tb.Deleted);
                     Tb.Deleted := True;
                  end if;
               end;
            end Maybe_Replace_Fake_Tab;

         --  Start of processing for Append_Tab

         begin
            if not Alignment_Enabled (Cmd) then
               return;
            end if;

            if Present (Tree) and then Tree.Kind = Ada_With_Clause then
               if not Tree.As_With_Clause.F_Has_Limited
                 and then not Tree.As_With_Clause.F_Has_Private
               then
                  Pa   := No_Ada_Node;
                  Tr   := No_Ada_Node;
               else
                  return; -- ignore "limited with" and "private with"
               end if;
            end if;

            Maybe_Replace_Fake_Tab;

            Append
              (Tabs,
               Tab_Rec'
                 (Pa,
                  Tr,
                  Token           => Token_Text,
                  Insertion_Point => <>,
                  Index_In_Line   => Index_In_Line,
                  Col             => <>,
                  Num_Blanks      => <>,
                  Is_Fake         => False,
                  Is_Insertion_Point => Is_Insertion_Point,
                  Deleted => False));
            Append_Tab_Tokn (New_Tokns, Last_Index (Tabs));

            --  Append a fake tab if appropriate

            if Present (Tree) and then not Is_Insertion_Point then
               case Tree.Kind is
                  when Ada_Object_Decl |
                    Ada_Extended_Return_Stmt_Object_Decl |
                    Ada_Number_Decl |
                    Ada_Discriminant_Spec |
                    Ada_Component_Decl =>
                     if Is_Generic_Formal_Object_Decl (Tree) then
                        pragma Assert (Tree.Kind = Ada_Object_Decl);
                        --  generic formal object

                        if Index_In_Line = 3 then
                           pragma Assert (Token_Text = Name_Tab_In_Out);
                           Append
                             (Tabs,
                              Tab_Rec'
                                (Parent          => Pa,
                                 Tree            => Tr,
                                 Token           => Name_Assign,
                                 Insertion_Point => <>,
                                 Index_In_Line   => 4,
                                 Col             => <>,
                                 Num_Blanks      => <>,
                                 Is_Fake         => True,
                                 Is_Insertion_Point => False,
                                 Deleted => False));
                           Append_Tab_Tokn (New_Tokns, Last_Index (Tabs));
                        end if;
                     else
                        if Index_In_Line = 1 then
                           pragma Assert (Token_Text = Name_Colon);
                           Append
                             (Tabs,
                              Tab_Rec'
                                (Parent          => Pa,
                                 Tree            => Tr,
                                 Token           => Name_Assign,
                                 Insertion_Point => <>,
                                 Index_In_Line   => 2,
                                 Col             => <>,
                                 Num_Blanks      => <>,
                                 Is_Fake         => True,
                                 Is_Insertion_Point => False,
                                 Deleted => False));
                           Append_Tab_Tokn (New_Tokns, Last_Index (Tabs));
                        end if;
                     end if;

                  when Ada_Param_Spec =>
                     if Index_In_Line = 3 then
                        pragma Assert (Token_Text = Name_Tab_In_Out);
                        Append
                          (Tabs,
                           Tab_Rec'
                             (Parent          => Pa,
                              Tree            => Tr,
                              Token           => Name_Assign,
                              Insertion_Point => <>,
                              Index_In_Line   => 4,
                              Col             => <>,
                              Num_Blanks      => <>,
                              Is_Fake         => True,
                              Is_Insertion_Point => False,
                              Deleted => False));
                        Append_Tab_Tokn (New_Tokns, Last_Index (Tabs));
                     end if;

                  when Ada_With_Clause =>
                     if Index_In_Line = 1 then
                        pragma Assert (Token_Text = Name_With);
                        Append
                          (Tabs,
                           Tab_Rec'
                             (Parent          => Pa,
                              Tree            => Tr,
                              Token           => Name_Use,
                              Insertion_Point => <>,
                              Index_In_Line   => 2,
                              Col             => <>,
                              Num_Blanks      => <>,
                              Is_Fake         => True,
                              Is_Insertion_Point => False,
                              Deleted => False));
                        Append_Tab_Tokn (New_Tokns, Last_Index (Tabs));
                     end if;

                  when Ada_Variant |
                    Ada_Quantified_Expr |
                    Ada_Assign_Stmt |
                    Ada_Case_Stmt_Alternative |
                    Ada_Case_Expr_Alternative |
                    Ada_Select_When_Part |
                    Ada_Component_Clause |
                    Ada_Exception_Handler |
                    Ada_Exception_Decl |
                    Ada_Membership_Expr =>
                     null;

                  when Ada_Pragma_Argument_Assoc |
                    Ada_Aspect_Assoc |
                    Ada_Discriminant_Assoc       |
                    Ada_Aggregate_Assoc |
                    Ada_Param_Assoc =>
                     null;

                  when others =>
                     --  No other tree kinds have tabs
                     pragma Assert (False, Tree.Kind'Img);
               end case;
            end if;
         end Append_Tab;

         procedure Subtrees_To_Ada
           (Tree               : Ada_Tree;
            Pre, Between, Post : Tok_Template)
         is
            pragma Assert (Tree.Kind in Ada_Ada_List);
            Prev_With : With_Clause := No_With_Clause;
            --  See Use_Same_Line below
         begin
            if Subtree_Count (Tree) = 0 then
               return;
            end if;

            Interpret_Template (Pre, Subtrees => Empty_Tree_Array);

            for Index in 1 .. Subtree_Count (Tree) loop
               declare
                  Subt : constant Ada_Tree := Subtree (Tree, Index);

                  function Use_Same_Line return Boolean;
                  --  Special case for use_package_clauses: We want to print "with
                  --  A.B; use A.B;" on one line. Also, things like "with A.B; use
                  --  A; use A.B;". This returns True in these cases. We don't do
                  --  this special processing for use type clauses.

                  function Has_Prefix (X, Y : Ada_Tree) return Boolean with
                     Pre => X.Kind in Ada_Identifier | Ada_Dotted_Name
                     and then Y.Kind in Ada_Identifier | Ada_Dotted_Name;
                     --  True if X contains Y, as in "A.B.C.D" contains "A.B".
                     --  I.e. if Y is a prefix of X.

                  function Has_Prefix (X, Y : Ada_Tree) return Boolean is
                  begin
                     return Has_Prefix
                       (L_Full_Name (X.As_Name), L_Full_Name (Y.As_Name));
                  end Has_Prefix;

                  function Use_Same_Line return Boolean is
                  begin
                     --  For a with clause followed by one or more use package
                     --  clauses, Prev_With will be the with clause when
                     --  processing the use clauses. Otherwise, Prev_With is null.

                     if Is_Nil (Prev_With)
                       or else Arg (Cmd, Use_On_New_Line)
                     then
                        return False; -- usual case
                     end if;

                     declare
                        pragma Assert (Prev_With.Kind = Ada_With_Clause);
                        With_Names : constant Name_List := F_Packages (Prev_With);
                        Next_Subtree : constant Ada_Tree :=
                          Subtree (Tree, Index + 1);
                     begin
                        if Next_Subtree.Kind = Ada_Use_Package_Clause then
                           declare
                              Use_Names : constant Name_List :=
                                Next_Subtree.As_Use_Package_Clause.F_Packages;
                           begin
                              if Subtree_Count (With_Names) = 1
                                and then Subtree_Count (Use_Names) = 1
                              then
                                 declare
                                    W : constant Ada_Tree := Subtree (With_Names, 1);
                                    U : constant Ada_Tree := Subtree (Use_Names, 1);
                                 begin
                                    if Has_Prefix (W, U)
                                      or else Has_Prefix (U, W)
                                    then
                                       return True;
                                    end if;
                                 end;
                              end if;
                           end;
                        end if;
                     end;

                     return False; -- usual case
                  end Use_Same_Line;

               begin
                  pragma Assert (Tree.Kind not in Ada_If_Stmt | Ada_Elsif_Stmt_Part);
                  --  No need for If_Stmt_Check here

                  declare
                     New_Lev : Nesting_Level := New_Level (Cur_Level, Pre);
                  begin
                     New_Lev := Nesting_Level'Max
                       (New_Lev, New_Level (Cur_Level, Between));
                     New_Lev := Nesting_Level'Max
                       (New_Lev, New_Level (Cur_Level, Post));
                     --  ???Shouldn't New_Lev use the entire template?
                     Subtree_To_Ada (Subt, New_Lev, Index);
                  end;

                  if Present (Subt) then
                     case Subt.Kind is
                        when Ada_With_Clause =>
                           if not Subt.As_With_Clause.F_Has_Limited
                             and then not Subt.As_With_Clause.F_Has_Private
                           then
                              Prev_With := Subt.As_With_Clause;
                           else
                              --  ignore "limited with" and "private with"
                              Prev_With := No_With_Clause;
                           end if;
                        when Ada_Use_Package_Clause =>
                           null; -- Leave Prev_With alone
                        when others =>
                           Prev_With := No_With_Clause;
                     end case;

                     if Index < Subtree_Count (Tree) then
                        declare
                           Same_Line : constant Boolean := Use_Same_Line;
                           use Alternative_Templates;
                           pragma Assert
                             (if Same_Line
                                then Between = Tok_Alt_Table (Semi_LB_Alt));
                           Tween : constant Tok_Template :=
                             (if Same_Line then
                                (if Ada_Tree (Prev_With) = Subtree (Tree, Index)
                                   then Tok_Alt_Table (Semi_Soft)
                                   else Tok_Alt_Table (Semi_LB_Alt))
                              else Between);
                        begin
                           Interpret_Template
                             (Tween, Subtrees => Empty_Tree_Array);
                           if Same_Line then
                              Append_Tab
                                (Parent        => No_Ada_Node,
                                 Tree          => No_Ada_Node,
                                 Token_Text    => Name_Use,
                                 Index_In_Line => 2,
                                 Is_Insertion_Point => False);
                           end if;
                        end;

                     else
                        pragma Assert (Index = Subtree_Count (Tree));
                        Interpret_Template (Post, Subtrees => Empty_Tree_Array);
                     end if;
                  end if;
               end;
            end loop;
         end Subtrees_To_Ada;

         procedure Interpret_Template
           (TT        : Tok_Template   := Tok_Template_Table (Tree.Kind);
            Subtrees  : Ada_Tree_Array := Pp.Actions.Subtrees (Tree);
            Cur_Level : Nesting_Level  := Subtree_To_Ada.Cur_Level;
            Kind      : Ada_Tree_Kind  := Tree.Kind)
         is
            subtype Subtrees_Index is Query_Index range 1 .. Subtrees'Last;
            Used : array (Subtrees_Index) of Boolean := (others => False);
            Cur_Subtree_Index : Query_Count := 0;
            Inst : Instr;

            procedure Do_Tab (Inst_Index : Instr_Index);

            procedure Do_Subtree (Subtree_Index : Query_Index);

            procedure Do_Opt_Subtree_Or_List
              (Subt : Ada_Tree; Subtree_Index : Query_Index);

            subtype Absent_Kinds is Ada_Node_Kind_Type with
              Predicate => Absent_Kinds in
              Ada_Abort_Absent |
              Ada_Abstract_Absent |
              Ada_Aliased_Absent |
              Ada_All_Absent |
              Ada_Constant_Absent |
              Ada_Limited_Absent |
              Ada_Not_Null_Absent |
              Ada_Private_Absent |
              Ada_Protected_Absent |
              Ada_Reverse_Absent |
              Ada_Synchronized_Absent |
              Ada_Tagged_Absent |
              Ada_Until_Absent |
              Ada_With_Private_Absent |

              Ada_Mode_Default |
              Ada_Overriding_Unspecified;
            --  This is needed because we have templates like "?~~ ~", which
            --  inserts a space after the subtree, which might be
            --  "private". But if "private" is not present, we don't want the
            --  space. Perhaps we should get rid of this, and move the space
            --  into the subtree, as in "private ".

            procedure Do_Opt_Subtree_Or_List
              (Subt : Ada_Tree; Subtree_Index : Query_Index) is
            begin
               if Present (Subt) then
                  case Subt.Kind is
                     when Absent_Kinds => null;
                     when Ada_Ada_List =>
                        Push (Tree_Stack, Subt);
                        Subtrees_To_Ada
                          (Subt, Inst.Pre, Inst.Between, Inst.Post);
                        Pop (Tree_Stack);

                     when others =>
                        Interpret_Template
                          (Inst.Pre, Subtrees => Empty_Tree_Array);
                        pragma Assert
                          (Kind not in Ada_If_Stmt | Ada_Elsif_Stmt_Part);
                        --  No need for If_Stmt_Check here
                        Subtree_To_Ada
                          (Subt, New_Level (Cur_Level, TT), Subtree_Index);
                        Interpret_Template
                          (Inst.Post, Subtrees => Empty_Tree_Array);
                  end case;
               end if;
            end Do_Opt_Subtree_Or_List;

            procedure Do_Subtree (Subtree_Index : Query_Index) is
               pragma Assert (Subtree_Index in Subtrees_Index);
               Subt : constant Ada_Tree := Subtrees (Subtree_Index);
            begin
               Used (Subtree_Index) := True;
               if Inst.Kind = Required_Subtree then
                  if Tree.Kind in Ada_If_Stmt | Ada_Elsif_Stmt_Part then
                     pragma Assert (Subtree_Index = 1);
                     If_Stmt_Check_1;
                  end if;

                  Subtree_To_Ada
                    (Subt, New_Level (Cur_Level, TT), Subtree_Index);

                  if Tree.Kind in Ada_If_Stmt | Ada_Elsif_Stmt_Part then
                     If_Stmt_Check_2 (Cur_Level);
                  end if;

               else
                  pragma Assert (Inst.Kind = Opt_Subtree_Or_List);
                  Do_Opt_Subtree_Or_List (Subt, Subtree_Index);
               end if;
            end Do_Subtree;

            procedure Do_Tab (Inst_Index : Instr_Index) is
               Par : constant Ada_Tree :=
                 (if Tree = Parent_Tree
                    then Ancestor_Tree (2) -- up one more level
                    else Parent_Tree);

               function Token_Text return Symbol;
               --  Computes the token to be associated with the tab.

               function Token_Text return Symbol is
               begin
                  if Inst.Kind = Tab_Insert_Point then
                     return Name_Tab_Insertion_Point;
                  elsif Tree.Kind = Ada_With_Clause then
                     return Name_With;
                  elsif Inst_Index = TT.Instructions'Last then
                     pragma Assert
                       (Tree.Kind in
                          Ada_Param_Spec | Ada_Object_Decl |
                          Ada_Extended_Return_Stmt_Object_Decl);
                     return Name_Tab_In_Out;

                  --  Except for the above special cases, we return
                  --  the text of the token after "^" in the template.

                  else
                     declare
                        Next_Inst : Instr renames
                          TT.Instructions (Inst_Index + 1);
                     begin
                        if Next_Inst.Kind = Continuation_Outdent then
                           return Name_R_Sq;
                           --  This happens for Comp_Clause_Alt.
                        else
                           pragma Assert (Next_Inst.Kind = Verbatim);
                           return Next_Inst.Text;
                        end if;
                     end;
                  end if;
               end Token_Text;

            begin
               Append_Tab
                 (Par,
                  Tree,
                  Token_Text,
                  Index_In_Line => Inst.Index_In_Line,
                  Is_Insertion_Point => Inst.Kind = Tab_Insert_Point);
            end Do_Tab;

         --  Start of processing for Interpret_Template

         begin
            for Inst_Index in TT.Instructions'Range loop
               Inst := TT.Instructions (Inst_Index);
               case Inst.Kind is
                  when Hard_Break | Hard_Break_No_Comment =>
                     Append_Line_Break
                       (Hard     => Arg (Cmd, Insert_Line_Breaks),
                        Affects_Comments => Inst.Kind = Hard_Break,
                        Level    => Cur_Level,
                        Kind     => Kind);

                  when Soft_Break =>
                     --  "#+n" is treated the same as "#n" (where n is a
                     --  digit), except that Max_Nesting_Increment ignores
                     --  the former.
                     Append_Line_Break
                       (Hard     => False,
                        Affects_Comments => False,
                        Level    => Cur_Level + Inst.Level_Inc,
                        Kind     => Kind);

                  when Indent =>
                     Indent (PP_Indentation (Cmd));
                  when Outdent =>
                     Indent (-PP_Indentation (Cmd));

                  when Continuation_Indent =>
                     Indent (PP_Indent_Continuation (Cmd));
                  when Continuation_Outdent =>
                     Indent (-PP_Indent_Continuation (Cmd));

                  when One_Space_Indent =>
                     Indent (1);
                  when One_Space_Outdent =>
                     Indent (-1);

                  when '(' =>
                     Append_And_Put (New_Tokns, '(');
                     Indent (1); -- extra indentation

                  when ')' =>
                     Append_And_Put (New_Tokns, ')');
                     Indent (-1);

                  when Tab | Tab_Insert_Point =>
                     Do_Tab (Inst_Index);

                  when Ignore_Subtree =>
                     Cur_Subtree_Index := Cur_Subtree_Index + 1;
                     Used (Cur_Subtree_Index) := True;

                  when Required_Subtree | Opt_Subtree_Or_List =>
                     if Inst.Index = 0 then
                        Cur_Subtree_Index := Cur_Subtree_Index + 1;
                     end if;

                     Do_Subtree
                       (Subtree_Index => (if Inst.Index = 0
                                            then Cur_Subtree_Index
                                            else Inst.Index));

                  when Verbatim =>
                     if Label_Seen and then Inst.T_Kind = ';' then
                        Label_Seen := False;
                     else
                        case Scanner.Token_Kind'(Inst.T_Kind) is
                           when Same_Text_Kind =>
                              Append_And_Put (New_Tokns, Inst.T_Kind);
                           when Stored_Text_Kind =>
                              Append_And_Put
                                (New_Tokns, Inst.T_Kind, Inst.Text);
                        end case;
                     end if;
               end case;
            end loop;
            pragma Assert
              (Used = (Subtrees_Index => True), "Not all used: " & Kind'Img);
         end Interpret_Template;

         use Alternative_Templates;

         procedure Maybe_Blank_Line;
         --  Implement the --insert-blank-lines. See also Replacements.

         procedure Maybe_Blank_Line is
            Insert_Blank_Line_Before : Boolean := False;
         begin
            if not Insert_Blank_Lines (Cmd) then
               return;
            end if;

            if Tree.Kind = Ada_Compilation_Unit then
               Insert_Blank_Line_Before := True;
            end if;

            case Tree.Kind is
               when Ada_Type_Decl |
                 Ada_Task_Type_Decl |
                 Ada_Protected_Type_Decl |
                 Ada_Single_Task_Decl |
                 Ada_Single_Protected_Decl |
                 Ada_Subp_Body |
                 Ada_Package_Decl | -- ???(non lib unit)
                 Ada_Package_Body |
                 Ada_Task_Body |
                 Ada_Protected_Body |
                 Ada_Entry_Body |
                 Ada_Generic_Subp_Decl |
                 Ada_Generic_Package_Decl |
                 Ada_Loop_Stmt | Ada_For_Loop_Stmt | Ada_While_Loop_Stmt |
                 Ada_Block_Stmt |
                 Ada_Extended_Return_Stmt |
                 Ada_Accept_Stmt |
                 Ada_Accept_Stmt_With_Stmts |
                 Ada_Select_Stmt |
                 Ada_If_Stmt |
                 Ada_Record_Rep_Clause |
                 Ada_Case_Stmt |
                 Ada_Variant_Part
                 --           Ada_Exception_Handler |???
                 =>
                  declare
                     Parent : constant Ada_Tree := Parent_Tree;
                  begin
                     if Parent.Kind in Ada_Ada_List then
                        if Subtree (Parent, 1) /= Tree then
                           Insert_Blank_Line_Before := True;
                        end if;
                     end if;
                  end;
               when Ada_Elsif_Stmt_Part =>
                  Insert_Blank_Line_Before := True;
               when others => null;
            end case;

            if Insert_Blank_Line_Before then
               pragma Assert (All_LB (All_LBI (Last (All_LBI))).Hard);
               Append_Line_Break
                 (Hard     => True,
                  Affects_Comments => False,
                  Level    => 1,
                  Kind     => Tree.Kind);
            end if;
         end Maybe_Blank_Line;

         function Is_Vertical_Aggregate (X : Ada_Tree'Class) return Boolean;
         --  True if X is an aggregate that should be formatted vertically. In
         --  particular, this is true if the --vertical-named-aggregates switch
         --  was given, and X is an aggregate, and all component associations
         --  are in named notation, and the aggregate appears in an appropriate
         --  context. An appropriate context is as the initial value of an
         --  object declaration, as the aggregate in an enumeration
         --  representation clause, or as the expression of a component
         --  association of an outer aggregate that is itself in such a
         --  context.

         --  Procedures for formatting the various kinds of node that are not
         --  fully covered by Str_Template_Table:

         procedure Do_Aggregate;
         procedure Do_Assign_Stmt;
         procedure Do_Compilation_Unit;
         procedure Do_Component_Clause;
         procedure Do_Handled_Stmts;
         procedure Do_Extended_Return_Stmt;
         procedure Do_For_Loop_Spec;

         procedure Do_Assoc;
         procedure Do_Un_Op (Tree : Ada_Tree);

         procedure Do_Bin_Op
           (Tree      : Ada_Tree;
            Is_Right  : Boolean;
            Cur_Level : Nesting_Level);
         --  Also handles some things that look like operators, like "and then".
         --  Is_Right is True if Tree is the right-hand argument of an outer
         --  binary operator. Otherwise (Tree is the left-hand argument, or Tree's
         --  parent is something else, like a parenthesized expression), Is_Right
         --  is False.

         procedure Do_List;
         procedure Do_Literal;
         procedure Do_Label;
         procedure Do_Parameter_Specification; -- also Formal_Object_Declaration
         procedure Do_Pragma;
         procedure Do_Qual_Expr;
         procedure Do_Select_When_Part;
         procedure Do_Params;
         procedure Do_Subp_Spec;
         procedure Do_Subp_Decl; -- subprograms and the like
         procedure Do_Call_Expr;
         procedure Do_Subtype_Indication;
         procedure Do_Task_Def;
         procedure Do_Type_Decl;
         procedure Do_Def_Or_Usage_Name;

         procedure Do_Others; -- anything not listed above

         function Is_Vertical_Aggregate (X : Ada_Tree'Class) return Boolean is
            function All_Named return Boolean is
              (Present (Subtree (Subtree (F_Assocs (X.As_Aggregate), 1), 1)));
            --  True if all component associations are named. We only need to
            --  check the first one, because of the restriction in Ada that
            --  positional associations can't follow named ones.
         begin
            return Result : Boolean := False do
               if Arg (Cmd, Vertical_Named_Aggregates)
                 and then Present (X)
                 and then X.Kind = Ada_Aggregate
                 and then All_Named
               then
                  if X.Parent.Kind in Ada_Object_Decl |
                    Ada_Assign_Stmt |
                    Ada_Enum_Rep_Clause
                  then
                     Result := True;
                  elsif X.Parent.Kind = Ada_Aggregate_Assoc then
                     declare
                        Agg : constant Ada_Tree := X.Parent.Parent.Parent;
                        pragma Assert (Agg.Kind = Ada_Aggregate);
                     begin
                        Result := Is_Vertical_Aggregate (Agg);
                        --  Recurse on outer aggregate
                     end;
                  end if;
               end if;
            end return;
         end Is_Vertical_Aggregate;

         procedure Do_Aggregate is
         begin
            if Is_Vertical_Aggregate (Tree) then
               Interpret_Alt_Template (Vertical_Agg_Alt);
            else
               Interpret_Alt_Template (Nonvertical_Agg_Alt);
            end if;
         end Do_Aggregate;

         procedure Do_Assign_Stmt is
         begin
            if Is_Vertical_Aggregate (F_Expr (Tree.As_Assign_Stmt)) then
               Interpret_Alt_Template (Assign_Vertical_Agg_Alt);
            else
               Interpret_Template;
            end if;
         end Do_Assign_Stmt;

         procedure Do_Compilation_Unit is
         begin
   --          Put ("--  \1 = \2", "Unit_Kind", Capitalize (Tree.Unit_Kind'Img));
   --          Interpret_Template ("$", Subtrees => Empty_Tree_Array);
   --          Put
   --            ("--  \1 = \2",
   --             "Unit_Class",
   --             Capitalize (Tree.Unit_Class'Img));
   --          Interpret_Template ("$", Subtrees => Empty_Tree_Array);
   --          Put
   --            ("--  \1 = \2",
   --             "Unit_Origin",
   --             Capitalize (Tree.Unit_Origin'Img));
   --          Interpret_Template ("$", Subtrees => Empty_Tree_Array);
   --          Interpret_Template ("$", Subtrees => Empty_Tree_Array);
            Subtrees_To_Ada
              (Subtree (Tree, 1),
               Pre     => Tok_Alt_Table (Empty_Alt),
               Between => Tok_Alt_Table (Semi_LB_Alt),
               Post    => Tok_Alt_Table (Semi_LB_LB_Alt));
            Subtree_To_Ada
              (Subtree (Tree, 2),
               Cur_Level + 1,
               Index_In_Parent => 2);
            Append_And_Put (New_Tokns, ';');
            Interpret_Alt_Template (Hard_Break_Alt, Subtrees => Empty_Tree_Array);
            Subtrees_To_Ada
              (Subtree (Tree, 3),
               Pre     => Tok_Alt_Table (Empty_Alt),
               Between => Tok_Alt_Table (Semi_LB_Alt),
               Post    => Tok_Alt_Table (Semi_LB_Alt));
         end Do_Compilation_Unit;

         procedure Do_Component_Clause is
            --  We use "`" to right-justify the three expressions X, Y, and Z in
            --  "at X range Y .. Z". We need to lift the Y and Z expressions up so
            --  they appear at the same level as X, so the Tree and Parent of the
            --  "`" will match that of the following "^". The Index_In_Lines must
            --  also match. The end result will be something like:
            --     Thing   at 0 range   0 ..  127;
            --     Thing_2 at 0 range 128 .. 1023;

            pragma Assert
              (Subtree (Tree, 3).As_Range_Spec.F_Range.As_Bin_Op.F_Op =
                 Ada_Op_Double_Dot);
            R : constant Ada_Tree :=
              Subtree (Tree, 3).As_Range_Spec.F_Range.As_Ada_Node;
            Subts : constant Ada_Tree_Array :=
              Subtrees (Tree) (1 .. 2) & Subtrees (R);
            pragma Assert (Subts'Last = 5);
         begin
            Interpret_Alt_Template (Comp_Clause_Alt, Subts);
         end Do_Component_Clause;

         procedure Do_Handled_Stmts is
         begin
            case Ada_Node'(Parent (Tree)).Kind is
               when Ada_Entry_Body |
                 Ada_Package_Body |
                 Ada_Subp_Body |
                 Ada_Task_Body |
                 Ada_Begin_Block |
                 Ada_Decl_Block =>
                  Interpret_Alt_Template (Handled_Stmts_With_Begin_Alt);
               when Ada_Extended_Return_Stmt | Ada_Accept_Stmt_With_Stmts =>
                  Interpret_Alt_Template (Handled_Stmts_With_Do_Alt);
               when others => raise Program_Error;
            end case;
         end Do_Handled_Stmts;

         procedure Do_Extended_Return_Stmt is
         begin
            --  If there are no statements or exception handlers, use short form

            if Is_Nil (Tree.As_Extended_Return_Stmt.F_Stmts) then
               Interpret_Alt_Template (Extended_Return_Stmt_Alt);
            else
               Interpret_Template;
            end if;
         end Do_Extended_Return_Stmt;

         type Precedence_Level is range 1 .. 8;
         function Precedence (Expr : Ada_Tree) return Precedence_Level;

         function Precedence (Expr : Ada_Tree) return Precedence_Level is
         begin
            case Expr.Kind is
               when Ada_Bin_Op | Ada_Relation_Op =>
                  case Expr.As_Bin_Op.F_Op is
                     when Ada_Op_In | Ada_Op_Not_In =>
                        raise Program_Error;
--  ???Don't treat membership tests as operators, for now
--               return 1;

                     when Ada_Op_And_Then | Ada_Op_Or_Else |
                       Ada_Op_And | Ada_Op_Or | Ada_Op_Xor =>
                        return 2;

                     when Ada_Op_Eq |
                       Ada_Op_Neq |
                       Ada_Op_Gt |
                       Ada_Op_Gte |
                       Ada_Op_Lt |
                       Ada_Op_Lte =>
                        return 3;

                     when Ada_Op_Double_Dot =>
                        return 4; -- ???

                     when Ada_Op_Plus | Ada_Op_Minus | Ada_Op_Concat =>
                        return 5;

                     when Ada_Op_Mult | Ada_Op_Div | Ada_Op_Mod | Ada_Op_Rem =>
                        return 6;

                     when Ada_Op_Pow =>
                        return 7;

                     --  Unary-only operator

                     when Ada_Op_Abs | Ada_Op_Not =>
                        raise Program_Error;
                  end case;

               --  Assume anything else is a unary operator or a primary
               --  (highest precedence)

               when others =>
                  return 8;
            end case;
         end Precedence;

         function Depends_RHS (Tree : Ada_Tree) return Ada_Tree is
         --  For a tree of the form "Depends => (A => xxx)", this returns
         --  the xxx.
           (Subtree (Subtree (Subtree (Subtree (Tree, 2), 2), 1), 2));

         function Depends_Hack (Tree : Ada_Tree) return Boolean is
         --  True if Tree is an Aspect_Assoc of the form "Depends => (A =>+ B)"
         --  or the same for Refined_Depends.
           (Tree.Kind = Ada_Aspect_Assoc
             and then W_Intern (Id_Name (Subtree (Tree, 1))) in
               Name_Depends | Name_Refined_Depends
             and then Depends_RHS (Tree).Kind = Ada_Un_Op
             and then Subtree (Depends_RHS (Tree), 1).Kind = Ada_Op_Plus);

         procedure Do_Assoc is
            --  Some have a single name before the "=>", and some have a list
            --  separated by "|".
            --  Positional_Notation is True if there are no names (no "=>").
            --  Single_Name is True if there is a single name before "=>",
            --  regardless of whether a list is allowed.

            Designator : constant Ada_Tree := Subtree (Tree, 1);
            Positional_Notation : constant Boolean :=
              Is_Nil (Designator) or else
                (Designator.Kind in Ada_Ada_List
                   and then Subtree_Count (Designator) = 0);
         begin
            if Positional_Notation then
               Interpret_Alt_Template (Pos_Notation_Assoc_Alt);
            else
               declare
                  Single_Name : constant Boolean :=
                    (if Tree.Kind = Ada_Discriminant_Assoc
                       then Subtree_Count
                         (Tree.As_Discriminant_Assoc.F_Ids) = 1
                     elsif Tree.Kind = Ada_Aggregate_Assoc
                       then Subtree_Count
                        (Tree.As_Aggregate_Assoc.F_Designators) = 1
                     else True);
                  Vertical : constant Boolean :=
                    Tree.Kind = Ada_Aggregate_Assoc
                    and then
                      Is_Vertical_Aggregate
                        (Tree.As_Aggregate_Assoc.F_R_Expr);
               begin
                  --  The Single_Name test is needed because the "[]" is not
                  --  properly nested with the "?~~~".
                  --  "! ^=>[# !]" doesn't work for discrims.
                  if Single_Name then
                     if Depends_Hack (Ancestor_Tree (3)) then
                        Interpret_Alt_Template (Depends_Hack_Alt);
                        --  Avoid the usual " " after "=>"; see Do_Un_Op below for an
                        --  explanation.
                     elsif Vertical then
                        Interpret_Alt_Template (Single_Name_Vertical_Assoc_Alt);
                     else
                        Interpret_Alt_Template (Single_Name_Assoc_Alt);
                     end if;
                  else
                     if Vertical then
                        Interpret_Alt_Template (Multi_Name_Vertical_Assoc_Alt);
                     else
                        Interpret_Alt_Template (Multi_Name_Assoc_Alt);
                     end if;
                  end if;
               end;
            end if;
         end Do_Assoc;

         procedure Do_Un_Op (Tree : Ada_Tree) is
            Expr : constant Un_Op := Tree.As_Un_Op;
         begin
            Append_And_Put (New_Tokns, F_Op (Expr));

            --  First we have a special case for the Depends and
            --  Refined_Depends aspect specifications. We want to pretend that
            --  "=>+" is an operator, so we print: "Depends => (A =>+ B)"
            --  instead of "Depends => (A => +B)". We don't bother with this
            --  for pragma [Refined_]Depends, because that's mainly for the
            --  compiler's implementation of the aspect, so we don't expect it
            --  to be used much.

            if Depends_Hack (Ancestor_Tree (4)) then
               pragma Assert (Subtree (Expr, 1).Kind = Ada_Op_Plus);
               Interpret_Alt_Template (Un_Op_Space_Alt, Subtrees (Expr));

            --  No special "[Refined_]Depends" case. Put a space after the
            --  operator, except for "+" and "-".

            else
               case F_Op (Expr) is
                  when Ada_Op_Plus | Ada_Op_Minus =>
                     Interpret_Alt_Template (Un_Op_No_Space_Alt, Subtrees (Expr));
                  when Ada_Op_Abs | Ada_Op_Not =>
                     Interpret_Alt_Template (Un_Op_Space_Alt, Subtrees (Expr));
                  when others => raise Program_Error;
               end case;
            end if;
         end Do_Un_Op;

         procedure Do_Bin_Op
           (Tree      : Ada_Tree;
            Is_Right  : Boolean;
            Cur_Level : Nesting_Level)
         is
            Expr : constant Bin_Op := Tree.As_Bin_Op;
            Oper : constant Ada_Op := F_Op (Expr);
            Is_Short_C : constant Boolean :=
              Oper in Ada_Op_And_Then | Ada_Op_Or_Else;
            Arg1 : constant Ada_Tree := F_Left (Expr).As_Ada_Node;
            Arg2 : constant Ada_Tree := F_Right (Expr).As_Ada_Node;

            --  The arguments can't have lower precedence than the expression as
            --  a whole; that's what precedence means -- you need parens to put
            --  a "+" inside a "*". The right-hand argument can't have equal
            --  precedence, because Ada has no right-associative binary operators.

            pragma Assert (Precedence (Arg1) >= Precedence (Tree));
            pragma Assert (Precedence (Arg2) > Precedence (Tree));

            Arg1_Higher : constant Boolean := Precedence (Arg1) > Precedence (Tree);
            --  Arg1 is higher precedence than Expr

         --  Calculate template fragments for the args (Arg1/2_T), that indent
         --  if the arg is a higher precedence binary operator than the whole
         --  expression.

         --  Start of processing for Do_Bin_Op

         begin
            if Oper = Ada_Op_Double_Dot then
               --  Old gnatpp did this separately from Do_Bin_Op.
               if Ancestor_Tree (3).Kind = Ada_Derived_Type_Def then
                  Interpret_Alt_Template (Dot_Dot_Wrong_Alt);
               elsif Parent_Tree.Kind = Ada_For_Loop_Spec then
                  Interpret_Alt_Template (Dot_Dot_For_Alt);
               else
                  Interpret_Alt_Template (Dot_Dot_Alt);
               end if;
               return;
            end if;

            --  The recursive calls to Do_Bin_Op below bypass the
            --  normal recursion via Subtree_To_Ada, so we need to pass along the
            --  Cur_Level to Interpret_Template. When we reach something that's
            --  not a binary op, we switch back to the normal recursion via
            --  Interpret_Template on the Arg. We split lines after the
            --  operator symbol, as in:
            --     Some_Long_Thing +
            --     Some_Other_Long_Thing
            --  except in the case of short circuits:
            --     Some_Long_Thing
            --     and then Some_Other_Long_Thing
            --  The --split-line-before-op switch causes all operators to be
            --  treated like short circuits in this regard.
            --
            --  All binary operators are surrounded by blanks, except for "**":
            --     Max : constant := 2**31 - 1;

            if Arg1.Kind in Ada_Bin_Op | Ada_Relation_Op then
               if Is_Right and then Arg1_Higher then
                  Interpret_Alt_Template
                    (Indent_Soft_Alt, Empty_Tree_Array, Cur_Level);
               end if;
               Do_Bin_Op
                 (Arg1,
                  Is_Right  => Is_Right,
                  Cur_Level => Cur_Level + (if Arg1_Higher then 1 else 0));
               if Is_Right and then Arg1_Higher then
                  Interpret_Alt_Template
                    (Outdent_Alt, Empty_Tree_Array, Cur_Level);
               end if;

            else
               Interpret_Alt_Template
                 (Subtree_Alt,
                  Subtrees  => (1 => Arg1),
                  Cur_Level => Cur_Level);
            end if;

         --  Don't split lines before or after "**"

            if (Is_Short_C or Arg (Cmd, Split_Line_Before_Op))
              and Oper /= Ada_Op_Pow
            then
               Interpret_Alt_Template (Soft_Alt, Empty_Tree_Array, Cur_Level);
            end if;

            if Oper = Ada_Op_Pow then
               Append_And_Put (New_Tokns, Oper); -- no blanks for "**"
            else
               Append_And_Put (New_Tokns, Spaces, Name_Space);
               Append_And_Put (New_Tokns, Oper);
               Append_And_Put (New_Tokns, Spaces, Name_Space);
            end if;

            if not (Is_Short_C or Arg (Cmd, Split_Line_Before_Op))
              and Oper /= Ada_Op_Pow
            then
               Interpret_Alt_Template (Soft_Alt, Empty_Tree_Array, Cur_Level);
            end if;

            if Arg2.Kind in Ada_Bin_Op | Ada_Relation_Op then
               Interpret_Alt_Template
                 (Indent_Soft_Alt, Empty_Tree_Array, Cur_Level + 1);
               Do_Bin_Op
                 (Arg2,
                  Is_Right  => True,
                  Cur_Level => Cur_Level + 1);
               Interpret_Alt_Template
                 (Outdent_Alt, Empty_Tree_Array, Cur_Level + 1);

            else
               Interpret_Alt_Template
                 (Subtree_Alt,
                  Subtrees  => (1 => Arg2),
                  Cur_Level => Cur_Level + 1);
            end if;
         end Do_Bin_Op;

         procedure Do_For_Loop_Spec is
         begin
            case Ada_Node'(Parent (Tree)).Kind is
               when Ada_For_Loop_Stmt =>
                  Interpret_Alt_Template (For_Loop_Spec_Stmt_Alt);
               when Ada_Quantified_Expr =>
                  --  In this case, the quantified_expression already printed
                  --  "for ".
                  Interpret_Alt_Template (For_Loop_Spec_Quant_Alt);
               when others => raise Program_Error;
            end case;
         end Do_For_Loop_Spec;

         procedure Do_List is
         --  This formats the list elements with a hard line break in between. It
         --  is called when a "!" in a template refers to a list subtree. If you
         --  don't want this formatting, you must use "?" instead of "!". See,
         --  for example, the template for Ada_If_Expression, where we want soft
         --  line breaks in between paths. Sometimes this is called for a list
         --  of one element, in which case the Between doesn't matter (e.g.
         --  Defining_Name_List, where there is only one).
         begin
            Subtrees_To_Ada
              (Tree,
               Pre => Tok_Alt_Table (Empty_Alt),
               Between => Tok_Alt_Table (Hard_Break_Alt),
               Post => Tok_Alt_Table (Empty_Alt));
         end Do_List;

         procedure Do_Literal is
            S : constant W_Str := Id_Name (Tree);
            V : Bounded_W_Str (Max_Length => 100);

            function Last_Digit
              (First : Positive; Based : Boolean) return Positive;
            --  Returns the index of the last digit in S starting at
            --  First

            procedure Put_With_Underscores
              (Part : W_Str; Grouping : Positive; Int : Boolean);
            --  Part is the integer part (before the '.', if any) or the
            --  fractional part (after the '.'). Int is True for the integer part.
            --  For example, for "16#12345.67890#e2", this will be called for Part
            --  = "12345" and Int = True, then for Part = "67890" and Int = False.
            --  We want to get "16#1_2345.6789_0#e2" (assuming Grouping = 4).

            procedure Put_With_Underscores
              (Part : W_Str; Grouping : Positive; Int : Boolean)
            is
               Count : Natural := (if Int then Part'Length else 0);
               Inc : constant Integer := (if Int then -1 else 1);
               --  For the integer part, we count downward from the Length; for
               --  the fractional part, we count upward from zero. If Count is
               --  divisible by Grouping, the next character should be preceded by
               --  an underscore, except there is never a leading underscore.
            begin
               for J in Part'Range loop
                  if J /= Part'First and then Count mod Grouping = 0 then
                     Append (V, '_');
                  end if;
                  Append (V, Part (J));
                  Count := Count + Inc;
               end loop;
            end Put_With_Underscores;

            function Last_Digit
              (First : Positive; Based : Boolean) return Positive
            is
            begin
               for J in First .. S'Last loop
                  if Is_Digit (S (J)) then
                     null;
                  elsif Based and then Is_Letter (S (J)) then
                     null;
                  else
                     return J - 1;
                  end if;
               end loop;
               return S'Last;
            end Last_Digit;

         --  Start of processing for Do_Literal

         begin
            pragma Assert (Check_Whitespace);
            Check_Whitespace := False;

            --  In most cases, we simply print out S. All of the complicated code
            --  below is for the --decimal-grouping and --based-grouping
            --  switches. If --decimal-grouping was used to specify a nonzero
            --  value, and we have a numeric literal without a base, and that
            --  literal contains no underscores, we insert underscores. Similarly
            --  for --based-grouping. A based literal is one containing "#" or
            --  ":"; note that "10#...#" is considered based, not decimal.

            case Tree.Kind is
               when Ada_String_Literal =>
                  Append_And_Put (New_Tokns, String_Lit, W_Intern (S));

               when Ada_Char_Literal =>
                  Append_And_Put (New_Tokns, Character_Literal, W_Intern (S));

               when Ada_Int_Literal | Ada_Real_Literal =>
                  declare
                     Sharp : constant Natural :=
                       (if Find (S, "#") /= 0 then Find (S, "#")
                        else Find (S, ":"));
                     Underscore : constant Natural := Find (S, "_");

                     Grouping : constant Natural :=
                       (if Underscore /= 0 then 0
                        elsif Sharp = 0 then Arg (Cmd, Decimal_Grouping)
                        else Arg (Cmd, Based_Grouping));

                     Int_First, Int_Last, Frac_First, Frac_Last : Natural;
                     --  These point to the slices of the literal that should
                     --  have underscores inserted. For example:
                     --     For 12345 or 12345E6:
                     --       S (Int_First .. Int_Last) = "12345"
                     --     For 12345.6789 or 16#12345.6789#E-3:
                     --       S (Int_First .. Int_Last) = "12345", and
                     --       S (Frac_First .. Frac_Last) = "6789"
                  begin
                     if Grouping = 0 then
                        Append_And_Put
                          (New_Tokns, Numeric_Literal, W_Intern (S));
                     else
                        Int_First := Sharp + 1;
                        Int_Last :=
                          Last_Digit (Int_First, Based => Sharp /= 0);
                        Append (V, S (1 .. Sharp));
                        Put_With_Underscores
                          (S (Int_First .. Int_Last),
                           Grouping, Int => True);
                        if Tree.Kind = Ada_Int_Literal then
                           Append (V, S (Int_Last + 1 .. S'Last));
                        else
                           Frac_First := Int_Last + 2; -- skip '.'
                           Frac_Last := Last_Digit
                             (Frac_First, Based => Sharp /= 0);
                           pragma Assert
                             (S (Int_Last + 1 .. Frac_First - 1) = ".");
                           Append (V, ".");
                           Put_With_Underscores
                             (S (Frac_First .. Frac_Last),
                              Grouping, Int => False);
                           Append (V, S (Frac_Last + 1 .. S'Last));
                        end if;
                        Append_And_Put
                          (New_Tokns, Numeric_Literal, W_Intern (+V));
                     end if;
                  end;

               when others => raise Program_Error;
            end case;

            Check_Whitespace := True;
         end Do_Literal;

         procedure Do_Label is
         begin
            --  We don't want to put ";" after a label; it's not really a
            --  statement. The Label_Seen flag suppresses the ";" that normally
            --  follows statements.

            Label_Seen := True;
            Interpret_Template;
         end Do_Label;

         procedure Do_Others is
         begin
            if Str_Template_Table (Tree.Kind) = null then
               raise Program_Error with "null template: " & Short_Image (Tree);
            else
               Interpret_Template;
            end if;
         end Do_Others;

         procedure Do_Parameter_Specification is
            Index : Query_Index := 1;
            AM : constant Boolean := Arg (Cmd, Align_Modes);
         begin
            --  F_Ids:
            Subtrees_To_Ada
              (Subtree (Tree, Index),
               Pre     => Tok_Alt_Table (Empty_Alt),
               Between => Tok_Alt_Table (Comma_Soft),
               Post    => Tok_Alt_Table (Empty_Alt));
            Interpret_Alt_Template
              (Parameter_Specification_Alt,
               Subtrees => Empty_Tree_Array);

            --  F_Has_Aliased:
            Index := Index + 1;

            if Subtree (Tree, Index).Kind = Ada_Aliased_Present then
               Subtree_To_Ada (Subtree (Tree, Index), Cur_Level + 1, Index);
               Append_And_Put (New_Tokns, Spaces, Name_Space);
            end if;

            --  Skip F_Has_Constant:
            if Tree.Kind = Ada_Object_Decl then
               Index := Index + 1;
            end if;

            --  F_Mode/F_Inout: ???Why not use the same name?
            Index := Index + 1;
            if Subtree (Tree, Index).Kind in Ada_Mode_In | Ada_Mode_In_Out then
               Append_And_Put (New_Tokns, Res_In);
               Append_And_Put (New_Tokns, Spaces, Name_Space);
            end if;
            if AM then
               Interpret_Alt_Template (Tab_2_Alt, Subtrees => Empty_Tree_Array);
            end if;
            if Subtree (Tree, Index).Kind in Ada_Mode_Out | Ada_Mode_In_Out then
               Append_And_Put (New_Tokns, Res_Out);
               Append_And_Put (New_Tokns, Spaces, Name_Space);
            end if;
            if AM then
               Interpret_Alt_Template (Tab_3_Alt, Subtrees => Empty_Tree_Array);
            end if;

            --  F_Type_Expr:
            Index := Index + 1;
            Subtree_To_Ada (Subtree (Tree, Index), Cur_Level + 1, Index);

            --  F_Default_Expr:
            Index := Index + 1;
            if Present (Subtree (Tree, Index)) then
               Interpret_Alt_Template
                 ((if AM then AM_Tab_4_Alt else Not_AM_Default_Alt),
                  Subtrees => (1 => Subtree (Tree, Index)));
            end if;

            --  Skip F_Renaming_Clause, F_Aspects:
            if Tree.Kind = Ada_Object_Decl then
               Index := Index + 1;
               Index := Index + 1;
            end if;

            pragma Assert (Index = Subtree_Count (Tree));
         end Do_Parameter_Specification;

         procedure Do_Pragma is
            With_Casing : constant W_Str :=
               Id_With_Casing (Id_Name (Tree.As_Pragma_Node.F_Id),
                               Tree.Kind, Is_Predef => False);
         begin
            Append_And_Put (New_Tokns, Res_Pragma);
            Append_And_Put (New_Tokns, Spaces, Name_Space);
            Append_And_Put (New_Tokns, Ident, W_Intern (With_Casing));
            Interpret_Alt_Template (Pragma_Alt);
         end Do_Pragma;

         procedure Do_Qual_Expr is
         begin
            if Subtree (Tree, 2).Kind in
              Ada_Aggregate | Ada_Null_Record_Aggregate
            then
               Interpret_Alt_Template (Qualified_Aggr_Alt);
            else
               Interpret_Template;
            end if;
         end Do_Qual_Expr;

         procedure Do_Select_When_Part is
         begin
            if Index_In_Parent = 1 then
               Interpret_Alt_Template (Select_When_Alt);
            else
               Interpret_Alt_Template (Select_Or_When_Alt);
            end if;
         end Do_Select_When_Part;

         procedure Do_Params is
            Is_Function : constant Boolean :=
              (if Is_Nil (Parent_Tree)
                 or else Parent_Tree.Kind in
                   Ada_Entry_Spec | Ada_Entry_Body |
                   Ada_Accept_Stmt | Ada_Accept_Stmt_With_Stmts
                 then False
                 else Present (Parent_Tree.As_Subp_Spec.F_Subp_Returns));
            Param_Count : Query_Count :=
              Subtree_Count (Tree.As_Params.F_Params);
         begin
            if Is_Function then
               Param_Count := Param_Count + 1; -- Add one extra for function result
            end if;
            if (Arg (Cmd, Par_Threshold) = 0 and then Arg (Cmd, Separate_Is))
              or else Param_Count > Query_Count (Arg (Cmd, Par_Threshold))
            then
               Interpret_Alt_Template (Par_Threshold_Alt);
            else
               Interpret_Alt_Template (Par_Alt);
            end if;
         end Do_Params;

         procedure Do_Subp_Spec is
            Params : constant Param_Spec_List :=
              (if Present (Tree.As_Subp_Spec.F_Subp_Params)
                 then F_Params (Tree.As_Subp_Spec.F_Subp_Params)
                 else No_Param_Spec_List);
            Is_Function : constant Boolean :=
              Present (Tree.As_Subp_Spec.F_Subp_Returns);
            Param_Count : Query_Count := Subtree_Count (Params);
         begin
            if Is_Function then
               Param_Count := Param_Count + 1; -- Add one extra for function result
            end if;
            if (Arg (Cmd, Par_Threshold) = 0 and then Arg (Cmd, Separate_Is))
              or else Param_Count > Query_Count (Arg (Cmd, Par_Threshold))
            then
               Interpret_Alt_Template (Spec_Threshold_Alt);
            else
               Interpret_Alt_Template (Spec_Alt);
               --  F_Name is optional for access-to-subp.
            end if;
         end Do_Subp_Spec;

         procedure Do_Subp_Decl is
            --  This is for subprogram declarations and the like -- everything
            --  that has a formal parameter list. Also subprogram
            --  instantiations, which have no such list.

            Spec : constant Subp_Spec :=
              (case Tree.Kind is
                 when Ada_Entry_Decl | Ada_Entry_Body => No_Subp_Spec,
                 when others => Get_Subp_Spec (Tree));

            Params : constant Param_Spec_List :=
              (case Tree.Kind is
                 when Ada_Entry_Decl =>
                   (if Present (Tree.As_Entry_Decl.F_Spec.F_Entry_Params)
                      then Tree.As_Entry_Decl.F_Spec.F_Entry_Params.F_Params
                      else No_Param_Spec_List),
                 when Ada_Entry_Body =>
                   (if Present (Tree.As_Entry_Body.F_Params)
                      then Tree.As_Entry_Body.F_Params.F_Params
                      else No_Param_Spec_List),
                 when others =>
                   (if Present (F_Subp_Params (Spec))
                      then F_Params (F_Subp_Params (Spec))
                      else No_Param_Spec_List));

--  ???The following gets SIGSEGV:
--            Is_Function : constant Boolean :=
--              Present (Spec) and then Present (F_Subp_Returns (Spec));
--            Param_Count : constant Query_Count :=
--              Subtree_Count (Params) +
--              Boolean'Pos (Is_Function); -- Add one extra for function result
            Is_Function : Boolean;
            Param_Count : Query_Count :=
              (if Params.Is_Null then 0 else Subtree_Count (Params));
         begin
            if Tree.Kind in Ada_Entry_Decl | Ada_Entry_Body then
               Is_Function := False;
            else
               Is_Function := Present (F_Subp_Returns (Spec));
               if Is_Function then
                  Param_Count := Param_Count + 1;
                  --  Add one extra for function result
               end if;
            end if;
            declare
               Subs : constant Ada_Tree_Array :=
                 (if Tree.Kind = Ada_Subp_Body
                    then Subtrees (Tree)(1 .. Subtree_Count (Tree) - 1) &
                         Tree.As_Subp_Body.P_Defining_Name.As_Ada_Node
                    else Subtrees (Tree));
            begin
               if (Arg (Cmd, Par_Threshold) = 0 and then Arg (Cmd, Separate_Is))
                 or else Param_Count > Query_Count (Arg (Cmd, Par_Threshold))
               then
                  Interpret_Template
                    (Tok_Subp_Decl_With_Hard_Breaks_Alt_Table (Tree.Kind),
                     Subtrees => Subs);
               else
                  Interpret_Template (Subtrees => Subs);
               end if;
            end;
         end Do_Subp_Decl;

         procedure Do_Call_Expr is
            function Past_Call_Threshold (Actuals : Ada_Tree) return Boolean is
               (Natural (Subtree_Count (Actuals)) >
                  Arg (Cmd, Call_Threshold)
                  and then
                  (for some Assoc of Subtrees (Actuals) =>
                     Present (Subtree (Assoc, 1))));
            --  True if there are more parameter associations than the threshold,
            --  and at least one of them is named.
         begin
            if Past_Call_Threshold (Tree.As_Call_Expr.F_Suffix) then
               Interpret_Alt_Template (Call_Threshold_Alt);
            else
               Interpret_Alt_Template (Call_Alt);
            end if;
         end Do_Call_Expr;

         procedure Do_Subtype_Indication is
         begin
            --  Why not discriminant constraint as well???
            --  If we put the "extra" space in the constraint,
            --  we could use Fix_RM_Spacing and get rid of
            --  Do_Subtype_Indication.
            if Arg (Cmd, Rm_Style_Spacing)
              and then Present (Subtree (Tree, 3))
              and then Subtree (Tree, 3).Kind = Ada_Index_Constraint
            then
               Interpret_Alt_Template (Subtype_Ind_Index_Alt);
            else
               Interpret_Alt_Template (Subtype_Ind_Alt);
            end if;
         end Do_Subtype_Indication;

         procedure Do_Task_Def is
            --  Replace the F_End_Id with the name found in our parent, which
            --  is an Ada_Task_Type_Decl or Ada_Single_Task_Decl.
            Subs : constant Ada_Tree_Array :=
              Subtrees (Tree)(1 .. Subtree_Count (Tree) - 1) &
                Tree.Parent.As_Basic_Decl.P_Defining_Name.As_Ada_Node;
         begin
            Interpret_Template (Subtrees => Subs);
         end Do_Task_Def;

         procedure Do_Type_Decl is
            Def : constant Type_Def := Tree.As_Type_Decl.F_Type_Def;
         begin
            if Def.Kind = Ada_Record_Type_Def
              or else (Def.Kind = Ada_Derived_Type_Def
                and then Present (Def.As_Derived_Type_Def.F_Record_Extension))
            then
               if Is_Nil (Tree.As_Type_Decl.F_Aspects) then
                  if Arg (Cmd, Split_Line_Before_Record) then
                     Interpret_Alt_Template (Record_Type_Decl_Split_Alt);
                  else
                     Interpret_Alt_Template (Record_Type_Decl_Alt);
                  end if;
               else
                  Interpret_Alt_Template (Record_Type_Decl_Aspects_Alt);
               end if;
            elsif Def.Kind = Ada_Access_To_Subp_Def then
               Interpret_Alt_Template (Access_To_Subp_Decl_Alt);
            elsif (Def.Kind = Ada_Enum_Type_Def
                     and then Arg (Cmd, Vertical_Enum_Types))
              or else (Def.Kind = Ada_Array_Type_Def
                         and then Arg (Cmd, Vertical_Array_Types))
            then
               Interpret_Alt_Template (Enum_Array_Decl_Alt);
            else
               Interpret_Alt_Template (Type_Decl_Alt);
            end if;
         end Do_Type_Decl;

         function Denoted_Decl (Id : Base_Id) return Basic_Decl;
         --  Returns the declaration denoted by Id. No_Basic_Decl if it doesn't
         --  denote anything. P_Referenced_Decl can raise Property_Error, in
         --  which case we return No_Basic_Decl.

         function Denoted_Def_Name
           (Decl : Basic_Decl; Id : Base_Id) return Base_Id;
         --  Returns the defining names denoted by Id.
         --  Decl is the declaration denoted by Id, or null.
         --  If Id doesn't denote anything, returns Id.
         --  ???Possible optimization: If we have never seen
         --  two differently-cased versions of the same identifier,
         --  we don't need to know what it denotes to use the
         --  right case.

         function Denoted_Decl (Id : Base_Id) return Basic_Decl is
         begin
            return Id.P_Referenced_Decl;
         exception
            --  ???At least some of these exceptions are bugs or
            --  not-yet-implemented features of libadalang.

            when Property_Error =>
               return No_Basic_Decl;
--  Uncomment the following to recover from libadalang failures:
--            when others =>
--               return No_Basic_Decl;
         end Denoted_Decl;

         function Denoted_Def_Name
           (Decl : Basic_Decl; Id : Base_Id) return Base_Id
         is
         begin
            if not Decl.Is_Null then
               --  Search through the defining names of the declaration to find
               --  one with the same name.
               for Def_Name of Decl.P_Defining_Names loop
                  if L_Name (Def_Name.P_Relative_Name) = L_Name (Id) then
                     return Def_Name.P_Relative_Name.As_Base_Id;
                  end if;
               end loop;
            end if;

            --  ??? Apparently sometimes Decl is passed but we still cannot
            --  find the defining id, which is why we fallback from the if
            --  above to this return.
            return Id;
--  Uncomment the following to recover from libadalang failures:
--         exception
--            when others =>
--               return Id;
         end Denoted_Def_Name;

         procedure Do_Def_Or_Usage_Name is
            Def : constant Boolean := Is_Def_Name (Tree.As_Base_Id);

            Decl : constant Basic_Decl :=
              (if Def then Tree.Parent.As_Basic_Decl
               elsif Arg (Cmd, Syntax_Only) then No_Basic_Decl
               else Denoted_Decl (Tree.As_Base_Id));
            Def_Name : constant Base_Id :=
              Denoted_Def_Name (Decl, Tree.As_Base_Id);
            pragma Assert (if Def then Def_Name = Tree.As_Base_Id);
            K : constant Ada_Node_Kind_Type :=
              (if Decl.Is_Null then Null_Kind else Decl.Kind);
            With_Casing : constant W_Str :=
                Id_With_Casing (Id_Name (Def_Name), Kind => K, Is_Predef => False);
            --  ???Is_Predef is wrong.
         begin
            Append_And_Put (New_Tokns, Ident, W_Intern (With_Casing));
         end Do_Def_Or_Usage_Name;

      --  Start of processing for Subtree_To_Ada

      begin
         if Is_Nil (Tree) then -- ???
            return;
         end if;

         Error_Sloc := Slocs.Start_Sloc (Sloc_Range (Tree));
         Push (Tree_Stack, Tree);

         Maybe_Blank_Line;

         case Tree.Kind is
            when Ada_Discrete_Subtype_Name |
              Ada_Unconstrained_Array_Index |
              Ada_Contract_Case_Assoc |
              Ada_Contract_Cases |
              Ada_Multi_Dim_Array_Assoc |
              Ada_Unconstrained_Array_Indices =>
               raise Program_Error with Short_Image (Tree) & " encountered";
               --  ???The above are not used

            when Ada_Compilation_Unit =>
               Do_Compilation_Unit;

            when Ada_Identifier =>
               Do_Def_Or_Usage_Name;

            when Ada_Int_Literal | Ada_Real_Literal |
              Ada_String_Literal | Ada_Char_Literal =>
               Do_Literal;

            when Ada_Label =>
               Do_Label;

            when Ada_Pragma_Node =>
               Do_Pragma;

            when Ada_Un_Op =>
               Do_Un_Op (Tree);

            when Ada_Bin_Op | Ada_Relation_Op =>
               Do_Bin_Op (Tree, Is_Right  => False, Cur_Level => Cur_Level);

            when Ada_For_Loop_Spec =>
               Do_For_Loop_Spec;

            when Ada_Task_Def =>
               Do_Task_Def;

            when Ada_Assign_Stmt =>
               Do_Assign_Stmt;

            when Ada_Param_Assoc |
              Ada_Aggregate_Assoc |
              Ada_Discriminant_Assoc |
              Ada_Pragma_Argument_Assoc =>
               Do_Assoc;

            when Ada_Aggregate =>
               Do_Aggregate;

            when Ada_Subtype_Indication =>
               Do_Subtype_Indication;

            when Ada_Component_Clause =>
               Do_Component_Clause;

            when Ada_Handled_Stmts =>
               Do_Handled_Stmts;

            when Ada_Extended_Return_Stmt =>
               Do_Extended_Return_Stmt;

            when Ada_Qual_Expr =>
               Do_Qual_Expr;

            when Ada_Param_Spec => -- ???generic formal object: | Ada_Object_Decl =>
               Do_Parameter_Specification;

            when Ada_Object_Decl =>
               if Is_Generic_Formal_Object_Decl (Tree) then
                  Do_Parameter_Specification;
               elsif Is_Vertical_Aggregate
                 (F_Default_Expr (Tree.As_Object_Decl))
               then
                  Interpret_Alt_Template (Obj_Decl_Vertical_Agg_Alt);
               else
                  Interpret_Template;
               end if;

            when Ada_Type_Decl =>
               Do_Type_Decl;

            when Ada_Constrained_Array_Indices =>
               declare
                  SI : constant Ada_Tree :=
                    Subtree (Tree.As_Constrained_Array_Indices.F_List, 1);
               begin
                  if Kind (SI) = Ada_Subtype_Indication then
                     declare
                        C : constant Constraint :=
                          SI.As_Subtype_Indication.F_Constraint;
                     begin
                        if Present (C)
                          and then Kind (C) = Ada_Range_Constraint
                          and then Kind (C.As_Range_Constraint.F_Range) =
                            Ada_Box_Expr
                        then
                           Interpret_Alt_Template (Boxy_Constrained_Alt);
                           goto Done_Constrained_Array_Indices;
                        end if;
                     end;
                  end if;
               end;
               Interpret_Template;

               <<Done_Constrained_Array_Indices>>

            when Ada_Select_When_Part =>
               Do_Select_When_Part;

            when Ada_Params =>
               Do_Params;

            when Ada_Subp_Spec =>
               Do_Subp_Spec;

            when Ada_Subp_Decl |
                 Ada_Abstract_Subp_Decl |
                 Ada_Expr_Function |
                 Ada_Null_Subp_Decl |
                 Ada_Subp_Renaming_Decl |
                 Ada_Subp_Body_Stub |
                 Ada_Formal_Subp_Decl |
                 Ada_Subp_Body |
                 Ada_Access_To_Subp_Def |
                 Ada_Generic_Subp_Decl |
                 Ada_Entry_Body |
                 Ada_Entry_Decl =>
               Do_Subp_Decl;

            when Ada_Call_Expr =>
               Do_Call_Expr;

            when Ada_Ada_List =>
               Do_List;

            when others =>
               Do_Others;
         end case;

         Pop (Tree_Stack);
      end Subtree_To_Ada;

      procedure Convert_Tree_To_Ada (Tree : Ada_Tree) is
      begin
         Scanner.Append_Tokn (New_Tokns, Scanner.Start_Of_Input);

         --  Append first link break. The Kind here doesn't matter.
         Append_Line_Break
           (Hard     => True,
            Affects_Comments => True,
            Level    => 1,
            Kind     => Null_Kind);

         Indent (Arg (Cmd, Initial_Indentation));

         pragma Assert (Check_Whitespace);
         Subtree_To_Ada (Tree, Cur_Level => 1, Index_In_Parent => 1);

         --  In Partial mode, we might need to add a line break

         if Partial or else not Arg (Cmd, Insert_Line_Breaks) then
            pragma Assert
              (Kind (Last (New_Tokns'Access)) not in Line_Break_Token);
            Append_Line_Break
              (Hard     => True,
               Affects_Comments => True,
               Level    => 1,
               Kind     => Null_Kind);
         end if;

         if Alignment_Enabled (Cmd) then
            Append
              (Tabs,
               Tab_Rec'
                 (Parent | Tree => No_Ada_Node,
                  others => <>));
            --  Append a sentinel tab, whose Position is greater than any
            --  actual position. This ensures that as we step through Tabs,
            --  there is always one more. We don't need the sentinel in the
            --  token stream.
         end if;

         Scanner.Append_Tokn (New_Tokns, Scanner.End_Of_Input);

         Indent (-Arg (Cmd, Initial_Indentation)); -- note negation
         pragma Assert (Is_Empty (Tree_Stack));
         pragma Assert (Cur_Indentation = 0);
      end Convert_Tree_To_Ada;

   --  Start of processing for Tree_To_Ada_2

   begin
      if not Template_Tables_Initialized then
         Init_Template_Tables (Cmd);

         if Debug_Mode then
            Put_Str_Templates;
         end if;
      end if;

      Convert_Tree_To_Ada (Root);
   end Tree_To_Ada_2;

   procedure Format_Vector
     (Cmd : Command_Line;
      Input : Char_Vector;
      Node : Ada_Node;
      In_Range : Char_Subrange;
      Output : out Char_Vector;
      Out_Range : out Char_Subrange;
      Messages : out Pp.Scanner.Source_Message_Vector)
   is
      pragma Unreferenced (In_Range, Out_Range);
      --  ???These are not yet implemented.

      Partial : constant Boolean := Is_Empty (Input);

      Src_Buf : Buffer;
      --  Buffer containing the text of the original source file

      Wide_Char_Encoding : constant System.WCh_Con.WC_Encoding_Method :=
        Wide_Character_Encoding (Cmd);

      type Out_File_Formats is (CRLF, LF);

      function Get_Out_File_Format return Out_File_Formats;
      --  This function is supposed to be used as a part of tool parameters
      --  processing. It tries to convert its parameter into the corresponding
      --  value of Out_File_Formats type using the following conventions:
      --
      --    "dos"     -> CRLF
      --    "crlf"    -> CRLF
      --    "unix"    -> LF
      --     "lf"     -> LF
      --
      --  Generates the error message and raises Parameter_Error if such a
      --  conversion is not possible.

      function Get_Out_File_Format return Out_File_Formats is
         Is_Windows : constant Boolean := GNAT.OS_Lib.Directory_Separator = '\';
         Val : constant String_Ref := Arg (Cmd, EOL);
      begin
         if Val = null then
            return (if Is_Windows then CRLF else LF);
         elsif Val.all = "dos" or else Val.all = "crlf" then
            return CRLF;
         elsif Val.all = "unix" or else Val.all = "lf" then
            return LF;
         else
            raise Program_Error; -- Should have been validated earlier.
   --         Error ("Unrecognized output file format " & Val.all);
   --         raise Parameter_Error;
         end if;
      end Get_Out_File_Format;

      Out_File_Format : constant Out_File_Formats := Get_Out_File_Format;
      --  Format of the tool report file(s)

      function Remove_Extra_Line_Breaks return WChar_Vector;
      --  Removes extra NL's. The result has exactly one NL at the beginning, and
      --  exactly one at the end. Also, if Preserve_Blank_Lines is False, we
      --  collapse 3 or more NL's in a row down to 2.  ???It would be cleaner if
      --  we didn't put multiple blank lines in in the first place.
      --
      --  This also converts LF to CRLF if appropriate.

      --  Wide_Text_IO accepts a Form parameter that inserts CR's on windows, but
      --  it doesn't do that on unix, so we insert CR's by hand.

      function Remove_Extra_Line_Breaks return WChar_Vector is
         Out_Buf : Buffer renames Lines_Data.Out_Buf;
         Add_CR : constant Boolean := Out_File_Format = CRLF;
         --  True if we should convert LF to CRLF -- if it was requested on the
         --  command line, or if we're on windows and nothing was requested.
      begin
         --  Optimize the case where we're not changing anything. The reason
         --  Remove_Extra_Line_Breaks keeps the initial NL is that this
         --  optimization wouldn't work otherwise.

         if Preserve_Blank_Lines (Cmd) and then not Add_CR then
            return To_Vector (Out_Buf);
         end if;

         declare
            Result : WChar_Vector;
         begin
            while Cur (Out_Buf) = NL loop
               Move_Forward (Out_Buf);
            end loop;
            Append (Result, W_LF);
            --  We don't want a CR here; caller skips the one LF character

            loop
               declare
                  NL_Count : Natural := 0;
               begin
                  while Cur (Out_Buf) = NL loop
                     Move_Forward (Out_Buf);
                     NL_Count := NL_Count + 1;
                  end loop;

                  exit when At_End (Out_Buf);

                  if not Preserve_Blank_Lines (Cmd) and then NL_Count > 2 then
                     NL_Count := 2;
                  end if;

                  for J in 1 .. NL_Count loop
                     if Add_CR then
                        Append (Result, W_CR);
                     end if;
                     Append (Result, W_LF);
                  end loop;
               end;

               pragma Assert (Cur (Out_Buf) /= NL);
               Append (Result, Cur (Out_Buf));
               Move_Forward (Out_Buf);
            end loop;

            if Add_CR then
               Append (Result, W_CR);
            end if;
            Append (Result, W_LF);
            Reset (Out_Buf);
            pragma Assert (Result (1) = NL);
            pragma Assert (Result (2) /= NL);
            if not Add_CR then
               pragma Assert (Result (Last_Index (Result) - 1) /= NL);
               pragma Assert (Result (Last_Index (Result)) = NL);
            end if;
            return Result;
         end;
      end Remove_Extra_Line_Breaks;

      procedure Tree_To_Ada;
      procedure Tree_To_Ada is
      begin
         if Debug_Mode then
            Utils.Dbg_Out.Output_Enabled := True;
         end if;

         Scanner.Get_Tokns (Src_Buf, Src_Tokns, Utils.Ada_Version);
         if Debug_Mode then
            Dbg_Out.Put ("Src_Tokens:\n");
            Scanner.Put_Tokens (Src_Tokns);
            Dbg_Out.Put ("end Src_Tokens:\n");
         end if;

         --  Note that if we're processing multiple files, we will get here
         --  multiple times, so data structures left over from last time must
         --  have been cleared out.

         pragma Assert (Cur_Indentation = 0);
         Assert_No_LB (Lines_Data);
         pragma Assert (Is_Empty (Tabs));
         Clear (Lines_Data.Out_Buf);
         Scanner.Clear (New_Tokns);

         --  If --comments-only was specified, format the comments and quit

         if Arg (Cmd, Comments_Only) then
            Do_Comments_Only (Lines_Data'Access, Src_Buf, Cmd);
         else
            --  Otherwise, convert the tree to text, and then run all the
            --  text-based passes.

            Tree_To_Ada_2 (Node, Cmd, Partial);
            Post_Tree_Phases
              (Lines_Data'Access, Messages, Src_Buf, Cmd, Partial);
         end if;
      end Tree_To_Ada;

   --  Start of processing for Format_Vector

   begin
      Clear (Src_Buf);
      Insert_Ada_Source
        (Src_Buf, Elems (Input) (1 .. Last_Index (Input)),
         Wide_Char_Encoding, Expand_Tabs => True);
      --  Expand tabs unconditionally. This differs from the behavior of
      --  the old gnatpp, which has an option for that (but only for
      --  comments).
      --  ???Encoding needs to match the call to libadalang.
      Reset (Src_Buf);

      Tree_To_Ada;

      if Scanner.Source_Message_Vectors.Is_Empty (Messages) then
         declare
            Out_Vec : constant WChar_Vector := Remove_Extra_Line_Breaks;
            Out_Arr : W_Str renames Elems (Out_Vec) (2 .. Last_Index (Out_Vec));
            --  2 to skip sentinel newline

            procedure Append_One (C : Character);
            procedure Append_One (C : Character) is
            begin
               Append (Output, C);
            end Append_One;
            procedure Encode is new
              System.WCh_Cnv.Wide_Char_To_Char_Sequence (Append_One);
         begin
            Clear (Output);
            for WC of Out_Arr loop
               Encode (WC, Wide_Char_Encoding);
            end loop;
         end;
      end if;
   end Format_Vector;

   procedure Per_File_Action
     (Tool : in out Pp_Tool;
      Cmd : Command_Line;
      File_Name : String;
      Input : String;
      BOM_Seen : Boolean;
      Unit : Analysis_Unit)
   is
      pragma Unreferenced (Tool);

      Output_Mode : constant Output_Modes := Get_Output_Mode (Cmd);
      Do_Diff : constant Boolean := Output_Mode in Replace_Modes;

      In_Vec, Out_Vec : Char_Vector;

      --  We initially write the output to Temp_Output_Name, then later rename it
      --  to Output_Name (except in Pipe mode). These are full pathnames. If we
      --  are overwriting the Source_Name, and it's a link link-->file, we want to
      --  overwrite file. But we put the temp file in the directory containing
      --  link, in case the directory containing file is not writable.

      function Get_Output_Name (Resolve_Links : Boolean) return String;
      function Get_Output_Name (Resolve_Links : Boolean) return String is
      begin
         pragma Assert (Environment.Initial_Dir = Current_Directory);
         return (case Output_Mode is
           when Pipe => "", -- not used
           when Output => Arg (Cmd, Output).all,
           when Output_Force => Arg (Cmd, Output_Force).all,
           when Replace_Modes => Normalize_Pathname
                                   (File_Name,
                                    Resolve_Links  => Resolve_Links,
                                    Case_Sensitive => True),

           when Output_Directory =>
             Compose (Arg (Cmd, Output_Directory).all,
                      Simple_Name (File_Name)));
      end Get_Output_Name;

      Output_Name : constant String := Get_Output_Name (Resolve_Links => True);

      Temp_Output_Name : constant String :=
          (if Output_Mode = Pipe then "" -- means standard output
           else Get_Output_Name (Resolve_Links => False) & "__GNATPP-TEMP");

      Output_Written : Boolean := False;
      --  True if Tree_To_Ada wrote the output to Temp_Output_Name. It always
      --  does, except in Replace_Modes if the output would be identical to the
      --  input.

      procedure Write_File_Name_File;
      --  If the Output_Mode /= Pipe, and Output_Written is True, add a pair of
      --  lines to the file name file.

      procedure Write_File_Name_File is
         use Text_IO, GNAT.Lock_Files;
         Lock_File_Name : constant String := File_Name_File_Name.all & ".lock";

         procedure Do_Writes;
         --  Write the two file names to the file name file. This is split out
         --  into a procedure so we can call it with and without file locking, as
         --  appropriate.

         procedure Do_Writes is
            File_Name_File : File_Type;
         begin
            Open (File_Name_File,
                  Mode => Append_File,
                  Name => File_Name_File_Name.all);
            Put_Line (File_Name_File, Temp_Output_Name);
            Put_Line (File_Name_File, Output_Name);
            Close (File_Name_File);
         end Do_Writes;

      --  Start of processing for Write_File_Name_File

      begin
         if Output_Mode /= Pipe then
            --  In -r, -rf, and -rnb modes, if the output was identical to the
            --  input, Output_Written will be False, so there is no
            --  Temp_Output_Name file, so we don't move it in that case. This can
            --  also happen if the exception handler at the end of Tree_To_Ada is
            --  executed.

            pragma Assert
              (if Output_Mode not in Replace_Modes then Output_Written);
            if not Output_Written then
               return;
            end if;

--            if Mimic_gcc and then (Verbose_Mode or else Debug_Flag_V) then
--               Put_Line
--                 ((if Output_Mode in Replace_Modes
--                     then "updating "
--                     else "creating ") &
--                  (if Debug_Flag_V then Short_Source_Name (SF) else Output_Name));
--            end if;

            --  The temp file was created, so write a pair (Temp_Output_Name,
            --  Output_Name) of lines to the file name file, so Finalize will know
            --  to rename temp --> output. This is done under lock, in case this
            --  is an inner process of an incremental build, and the -j switch of
            --  the builder is used to invoke this in parallel.

            if Arg (Cmd, Outer_Parallel) then
               pragma Assert (Mimic_gcc (Cmd));
               Lock_File (Lock_File_Name, Wait => 0.1, Retries => 5 * 60 * 10);
               --  Retry for 5 minutes, every 100 milliseconds.
               declare
                  --  We create a dummy object whose finalization calls
                  --  Unlock_File, so we don't leave stale lock files around even
                  --  in case of unhandled exceptions.

                  type Dummy_Type is new Ada.Finalization.Limited_Controlled with
                    null record;
                  procedure Finalize (Ignore : in out Dummy_Type);
                  procedure Finalize (Ignore : in out Dummy_Type) is
                  begin
                     Unlock_File (Lock_File_Name);
                  end Finalize;

                  Dummy : Dummy_Type;

               begin
                  Do_Writes;
               end;

            --  Otherwise, it's safe to do the writes without any locking. We want
            --  to avoid locking when possible, because it reduces the likelihood
            --  of stale locks left lying around. It's a little more efficient,
            --  too.

            else
               Do_Writes;
            end if;
         end if;
--      exception
--         when Lock_Error =>
--            Utils.Output.Error ("cannot create " & Lock_File_Name);
--            Utils.Output.Error ("delete it by hand if stale");
--            raise;
      end Write_File_Name_File;

      procedure Write_Str (Out_Vec : Char_Vector);
      procedure Write_Out_Buf;
      procedure Write_Src_Buf;
      --  Write_Out_Buf writes Out_Buf to the output. This is the normal
      --  case. Write_Src_Buf writes the Src_Buf to the output. Write_Str is the
      --  code common to both Write_Out_Buf and Write_Src_Buf.

      procedure Write_Str (Out_Vec : Char_Vector) is
         Out_File : File_Descriptor := Standout;
         Out_String : String renames Elems (Out_Vec) (1 .. Last_Index (Out_Vec));
         Status : Boolean;
      begin
   --  ???
   --      if False then -- ???Messes up the diff's.
   --         Formatted_Output.Put
   --           ("--  ???Inner_Loop_Count = \1\n",
   --            Image (Inner_Loop_Count));
   --      end if;

         Output_Written := True;
         if Temp_Output_Name /= "" then
            --  If Temp_Output_Name = "", use standard output; otherwise point
            --  open the file.
            Out_File := Create_File (Temp_Output_Name, Fmode => Binary);
            if Out_File = Invalid_FD then
               raise Program_Error with
                 "write of " & Temp_Output_Name & " failed";
            end if;
         end if;

         --  If a BOM (byte order mark) was found in the input, we want to put it
         --  in the output.

         if BOM_Seen then
   --         if Options.Output_Encoding /= System.WCh_Con.WCEM_UTF8 then
   --            raise Program_Error;
   --         end if;
            Write_File (Out_File, Ada.Strings.UTF_Encoding.BOM_8);
--            Put (W_Char'Val (16#FEFF#)); -- BOM as a wide character
         end if;

         Write_File (Out_File, Out_String);

         if Temp_Output_Name /= "" then
            Close (Out_File, Status);
            if not Status then
               raise Program_Error with
                 "write of " & Temp_Output_Name & " failed";
            end if;
         end if;
      end Write_Str;

      procedure Write_Out_Buf is
      begin
         --  In Do_Diff mode, don't write the output if it is identical to the
         --  input.

         if Do_Diff and then Out_Vec = In_Vec then
            pragma Assert (not Output_Written);
            return;
         end if;

         Write_Str (Out_Vec);
      end Write_Out_Buf;

      procedure Write_Src_Buf is
      begin
         pragma Assert (Is_Empty (Out_Vec));
         Write_Str (In_Vec);
      end Write_Src_Buf;

   --  Start of processing for Per_File_Action

   begin
      if Debug_Mode then
         Print (Unit);
--         Put ("With trivia\n");
--         PP_Trivia (Unit);
      end if;

--      case Output_Mode is
--         when Pipe | Replace_Modes | Default =>
--            pragma Assert (Res_File_Name = null);
--            pragma Assert (Out_Dir = null);
--         when Create_Modes =>
--            pragma Assert (Res_File_Name /= null);
--            pragma Assert (Out_Dir = null);
--         when Out_Directory =>
--            pragma Assert (Res_File_Name = null);
--            pragma Assert (Out_Dir /= null);
--
--            if Out_Dir.all =
--              Containing_Directory (Source_Name (SF))
--            then
--               Error ("--output-dir=" & Out_Dir.all);
--               Error (" contains input file " & Short_Source_Name (SF));
--               Error (" skipping " & Short_Source_Name (SF));
--               Error (" use -rnb to update source files in place");
--               return;
--            end if;
--      end case;
--
--      Set_Output_Encoding;
--
--      if Output_Mode = Replace_Backup and then
--         Is_Regular_File (Source_Name (SF) & NPP_Suffix)
--      then
--         Put (Standard_Error, "gnatpp: file ");
--         Put (Standard_Error,
--              To_Wide_String (Source_Name (SF) & NPP_Suffix));
--         Put (Standard_Error, " exists. Use '-rf' option to override");
--         New_Line (Standard_Error);
--         return;
--      end if;

      if Output_Mode in Replace_Backup | Replace_Force_Backup then

--         if Verbose_Mode then
--            Put (Standard_Error, "gnatpp: creating the back-up copy ");
--            Put (Standard_Error, "of the original source ");
--            Put (Standard_Error, To_Wide_String (Source_Name (SF)));
--            New_Line (Standard_Error);
--         end if;

         declare
            Backup_Name : constant String := File_Name & NPP_Suffix;
            Success : Boolean;
            use Wide_Text_IO;
         begin
            Copy_File
              (Name     => File_Name,
               Pathname => Backup_Name,
               Success  => Success,
               Mode     => Overwrite);

            if not Success then
               Put (Standard_Error,
                    "gnatpp: cannot create backup file ");
               Put (Standard_Error, To_Wide_String (Backup_Name));
               New_Line (Standard_Error);
            end if;
         end;

      end if;

--      pragma Assert (Is_Empty (Symtab));
      Append (In_Vec, Input);
      declare
         Messages : Scanner.Source_Message_Vector;
         use Scanner.Source_Message_Vectors;
         use type Ada.Containers.Count_Type;
         In_Range : constant Char_Subrange :=
           Utils.Char_Vectors.Char_Vectors.Full_Range (In_Vec);
         Ignored_Out_Range : Char_Subrange;
      begin
         Format_Vector
           (Cmd, In_Vec, Root (Unit), In_Range,
            Out_Vec, Ignored_Out_Range, Messages);
--        (CU, Cmd, Output_Name, Form_String,
--         Do_Diff, Output_Written, To_Ada => True);
--      --  We have to flush the cache here, because Unit_Id's get reused between
--      --  runs of this.
--      Flush_Cache;
--      Clear (Symtab);

         if not Is_Empty (Messages) then
            pragma Assert (Length (Messages) = 1);
            --  We only handle one message for now.
            Cmd_Error_No_Tool_Name
              (Scanner.Message_Image (File_Name, Messages (1).Sloc) &
                           ": " & String (To_Array (Messages (1).Text)));
         end if;
      end;

      --  Finally, print out the result

      Write_Out_Buf;
      Write_File_Name_File;
   exception
      --  If we got an error, don't produce output

      when Command_Line_Error | Command_Line_Error_No_Tool_Name =>
         raise;

      when others =>
         --  In order to avoid damaging the user's source code, if there is a bug
         --  (like a token mismatch in Final_Check), we avoid writing the output
         --  file in Do_Diff mode; otherwise, we write the input to the output
         --  unchanged. This happens only in production builds.
         --
         --  Include the source location in the error message, if available.

         declare
            use type Slocs.Source_Location;
            Loc : constant String :=
              (if Error_Sloc = Slocs.No_Source_Location
                 then "" else ":" & Slocs.Image (Error_Sloc));
         begin
            Text_IO.Put_Line
              (Text_IO.Standard_Error,
               Simple_Name (File_Name) & Loc &
                 ": pretty printing failed; unable to format");
         end;

         if Enable_Token_Mismatch then
            raise;
         else
            if Do_Diff then
               pragma Assert (not Output_Written);
            else
               Write_Src_Buf;
            end if;

            --  Reset Lines_Data to its initial state, so we don't blow up on
            --  subsequent files.

            Lines_Data := (others => <>);
         end if;
   end Per_File_Action;

   ---------------
   -- Tool_Help --
   ---------------

   procedure Tool_Help (Tool : Pp_Tool) is
      pragma Unreferenced (Tool);
      use Utils.Formatted_Output;
   begin
      pragma Style_Checks ("M200"); -- Allow long lines

      Put ("usage: gnatpp [options] {filename} {-files filename}\n");
      Put (" options:\n");
      Put (" --version - Display version and exit\n");
      Put (" --help    - Display usage and exit\n");
      Put ("\n");
      Put (" -Pproject     - use project file project\n");
      Put (" -U            - process all sources of the argument project\n");
      Put (" -U main       - process the closure of units rooted at unit main\n");
      Put (" -Xname=value  - specify an external reference for argument project file\n");
      Put (" -eL           - follow all symbolic links when processing project files\n");

      Put ("\n");
      Put (" --alignment -- alignment ON (default)\n");
      Put (" --no-alignment -- alignment OFF\n");
      Put (" --align-modes -- alignment of parameter modes ON (default)\n");
      Put (" --no-align-modes -- alignment of parameter modes OFF\n");

      Put ("casing switches:\n");
      Put (" --name-case-as-declared - usage names as declared (default)\n");
      Put (" --name-lower-case - names in lower case\n");
      Put (" --name-upper-case - names in upper case\n");
      Put (" --name-mixed-case - names in mixed case\n");

      Put ("attribute casing:\n");
      Put (" --attribute-lower-case\n");
      Put (" --attribute-upper-case\n");
      Put (" --attribute-mixed-case (default)\n");

      Put ("reserved word casing:\n");
      Put (" --keyword-lower-case (default)\n");
      Put (" --keyword-upper-case\n");

      Put ("enumeration literal casing:\n");
      Put (" --enum-case-as-declared\n");
      Put (" --enum-lower-case\n");
      Put (" --enum-upper-case\n");
      Put (" --enum-mixed-case\n");

      Put ("type and subtype casing:\n");
      Put (" --type-case-as-declared\n");
      Put (" --type-lower-case\n");
      Put (" --type-upper-case\n");
      Put (" --type-mixed-case\n");

      Put ("named number casing:\n");
      Put (" --number-case-as-declared\n");
      Put (" --number-lower-case\n");
      Put (" --number-upper-case\n");
      Put (" --number-mixed-case\n");

      Put ("pragma casing:\n");
      Put (" --pragma-mixed-case\n");
      Put (" --pragma-lower-case\n");
      Put (" --pragma-upper-case\n");
      Put ("\n");

      Put (" --based-grouping=n  - underscores in based literals every n characters\n");

      Put (" --comments-unchanged - do not format comments\n");
      Put (" --comments-gnat-indentation - GNAT style comment line indentation (default)\n");
      Put (" --comments-gnat-beginning - GNAT style comment beginning\n");
      Put (" --comments-fill - fill comment blocks\n");
      Put (" --comments-special - do not change comments with a special character " &
            "just after --\n");
      Put (" --comments-only - format just the comments\n");

      Put (" --indentation=n - indentation level, n from 1 .. 9 (default 3)\n");
      Put (" --indent-continuation - indentation level for continuation lines (default one less than --indentation)\n");

      Put (" --dictionary=<file> - set <file> as the dictionary file defining casing " &
            "exceptions\n");
      Put (" --dictionary=-      - do not use RM-defined casing for predefined " &
            "names\n");

      Put (" --decimal-grouping=n  - underscores in decimal literals every n characters\n");

      Put (" --ff-after-pragma-page - put Form Feed after a pragma Page\n");

      Put (" --max-line-length=nnn - set maximum line length (default 79)\n");

      Put (" --pp-off=xxx - Use ""--xxx"" as the comment string to disable\n");
      Put ("                pretty printing instead of the default " &
              """--!pp off""\n");
      Put (" --pp-on=xxx - Use ""--xxx"" as the comment string to reenable\n");
      Put ("                pretty printing instead of the default " &
              """--!pp on""\n");

      Put (" --RTS=<dir> - the same as gcc --RTS option\n");

      Put (" --quiet / -q  - quiet mode\n");

      Put (" --no-separate-is        - try not to place 'IS' on a separate " &
            " line in\n");
      Put ("                           a subprogram body\n");
      Put (" --separate-loop-then    - use a separate line for LOOP and " &
            "THEN keywords\n");

      Put (" --no-separate-loop-then - do not use a separate line for LOOP " &
            "and THEN\n");
      Put ("                           keywords, uncompatible with " &
            "--separate-loop-then\n");

      Put (" --use-on-new-line       - use separate lines for USE clauses\n");
      Put ("                           in a context clause\n");

      Put (" --insert-blank-lines    - insert blank lines where appropriate\n");

      Put (" --preserve-blank-lines  - preserve blank lines in the input\n");

      Put (" --insert-line-breaks    - insert line breaks where appropriate (default)\n");
      Put (" --no-insert-line-breaks    - do not insert line breaks\n");

      Put (" --split-line-before-op  - operator on next line\n");
      Put (" --split-line-before-record  - ""record"" on next line\n");
      Put (" --indent-named-statements - named statements indented more than name\n");

      Put (" --RM-style-spacing      - no extra space before " &
            "'(' and ':'\n");

      Put (" --par-threshold=nnn     - if the number of parameter specifications is greater\n");
      Put ("                           than nnn, each specification starts from a new line\n");

      Put (" --call-threshold=nnn    - if the number of parameter associations in a call is\n");
      Put ("                           greater than nnn and there is at least one named\n");
      Put ("                           association, each association starts from a new line\n");

      Put (" --vertical-enum-types - multi-line enumeration types\n");
      Put (" --vertical-array-types - multi-line array types\n");
      Put (" --vertical-named-aggregates - multi-line named aggregates\n");
      Put (" --vertical-case-alternatives -multi-line case alternatives\n");

      Put (" --incremental -- incremental processing on a per-file basis\n");
      Put (" -jn - n is the maximal number of processes to carry out\n");

      Put (" --syntax-only  - do not run semantic analysis (default)\n");
      Put (" --no-syntax-only  - run semantic analysis\n");

      Put (" --verbose / -v  - verbose mode\n");

      Put (" -dd - progress indicator verbose mode\n");
      Put ("\n");

      Put ("Output file control:\n");
      Put (" --replace - replace the argument source with the pretty-printed " &
            "source (default)\n");
      Put (" --output-dir=dir / --dir=dir -- create output files in dir\n");
      Put (" --replace-backup  - replace the argument source with the pretty-printed " &
            "source and copy the\n");
      Put ("        argument source into filename.npp\n");
      Put (" --replace-force-backup   - same as --replace-backup, but overwrites " &
            " an existing filename.npp\n");
      Put (" --pipe - send the output to standard output\n");
      Put (" --output=output_file - write the output into output_file. Give up " &
            "if output_file\n");
      Put ("                  already exists\n");
      Put (" --output-force=output_file - write the output into output_file, " &
            "overriding the existing\n");
      Put ("                   file\n");

      Put ("\n");

      Put (" filename - the name of the Ada source file to be reformatted.\n");
      Put ("            Wildcards are allowed\n");
      Put (" --files=filename - the name of a text file containing a list\n");
      Put ("                   of Ada source files to reformat\n");
      Put (" --ignore=filename - do not process sources listed in filename\n");
      Put (" --eol=text_format - sets the format of the gnatpp output " &
        "file(s),\n");
      Put ("       text_format can be - 'unix' or 'lf'   - lines end with " &
        "LF character\n");
      Put ("                          - 'dos'  or 'crlf' - lines end with " &
        "CRLF characters\n");

      Put (" --wide-character-encoding=(8|b) - set the wide " &
        "character encoding of the result file\n");
      Put ("    8 - UTF-8 encoding\n");
      Put ("    b - Brackets encoding (default)\n");
      Put ("\n");

      Put ("\n\nReport bugs to report@adacore.com\n");

      pragma Style_Checks ("M79");
   end Tool_Help;

end Pp.Actions;

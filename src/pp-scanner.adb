------------------------------------------------------------------------------
--                                                                          --
--                            GNAT2XML COMPONENTS                           --
--                                                                          --
--                      G N A T 2 X M L . S C A N N E R                     --
--                                                                          --
--                                 B o d y                                  --
--                                                                          --
--                     Copyright (C) 2012-2017, AdaCore                     --
--                                                                          --
-- Gnat2xml is free software; you can redistribute it and/or modify it      --
-- under terms of the  GNU General Public License  as published by the Free --
-- Software Foundation;  either version 2,  or  (at your option)  any later --
-- version. Gnat2xml is distributed  in the hope  that it will be useful,   --
-- but WITHOUT ANY WARRANTY; without even the implied warranty of MER-      --
-- CHANTABILITY or  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General  --
-- Public License for more details. You should have received a copy of the  --
-- GNU General Public License distributed with GNAT; see file COPYING. If   --
-- not, write to the Free Software Foundation, 59 Temple Place Suite 330,   --
-- Boston, MA 02111-1307, USA.                                              --
-- The gnat2xml tool was derived from the Avatox sources.                   --
------------------------------------------------------------------------------

with Unchecked_Conversion;
with Text_IO;
with Utils.Predefined_Symbols; use Utils.Predefined_Symbols;
with Pp.Error_Slocs; use Pp.Error_Slocs;

package body Pp.Scanner is

   use Syms;

   Token_To_Symbol_Map : constant array (Same_Text_Kind) of Symbol :=
     (Start_Of_Input | End_Of_Input => Name_Empty,
      False_End_Of_Line => Name_Empty,
      True_End_Of_Line | Blank_Line => Name_NL,

      '!' => Intern ("!"),
      '#' => Intern ("#"),
      '$' => Intern ("$"),
      '?' => Intern ("?"),
      '[' => Intern ("["),
      '\' => Intern ("\"),
      ']' => Intern ("]"),
      '^' => Intern ("^"),
      '`' => Intern ("`"),
      '{' => Intern ("{"),
      '}' => Intern ("}"),
      '~' => Intern ("~"),

      '-' => Intern ("-"),
      ''' => Intern ("'"),
      '&' => Intern ("&"),
      '(' => Intern ("("),
      ')' => Intern (")"),
      '+' => Intern ("+"),
      ',' => Intern (","),
      ':' => Intern (":"),
      ';' => Intern (";"),
      '|' => Intern ("|"),
      '@' => Intern ("@"),
      '<' => Intern ("<"),
      '>' => Intern (">"),
      '.' => Intern ("."),
      '*' => Intern ("*"),
      '=' => Intern ("="),
      '/' => Intern ("/"),

      Arrow => Intern ("=>"),
      Dot_Dot => Intern (".."),
      Exp_Op => Intern ("**"),
      Not_Equal => Intern ("/="),
      Greater_Or_Equal => Intern (">="),
      Right_Label_Bracket => Intern (">>"),
      Less_Or_Equal => Intern ("<="),
      Left_Label_Bracket => Intern ("<<"),
      Box => Intern ("<>"),
      Colon_Equal => Intern (":="),

      --  Ada 83 reserved words

      Res_Abort => Intern ("abort"),
      Res_Abs => Intern ("abs"),
      Res_Accept => Intern ("accept"),
      Res_Access => Intern ("access"),
      Res_And => Intern ("and"),
      Res_All => Intern ("all"),
      Res_Array => Intern ("array"),
      Res_At => Intern ("at"),
      Res_Begin => Intern ("begin"),
      Res_Body => Intern ("body"),
      Res_Case => Intern ("case"),
      Res_Constant => Intern ("constant"),
      Res_Declare => Intern ("declare"),
      Res_Delay => Intern ("delay"),
      Res_Delta => Intern ("delta"),
      Res_Digits => Intern ("digits"),
      Res_Do => Intern ("do"),
      Res_Else => Intern ("else"),
      Res_Elsif => Intern ("elsif"),
      Res_End => Intern ("end"),
      Res_Entry => Intern ("entry"),
      Res_Exception => Intern ("exception"),
      Res_Exit => Intern ("exit"),
      Res_For => Intern ("for"),
      Res_Function => Intern ("function"),
      Res_Generic => Intern ("generic"),
      Res_Goto => Intern ("goto"),
      Res_If => Intern ("if"),
      Res_In => Intern ("in"),
      Res_Is => Intern ("is"),
      Res_Limited => Intern ("limited"),
      Res_Loop => Intern ("loop"),
      Res_Mod => Intern ("mod"),
      Res_New => Intern ("new"),
      Res_Not => Intern ("not"),
      Res_Null => Intern ("null"),
      Res_Of => Intern ("of"),
      Res_Or => Intern ("or"),
      Res_Others => Intern ("others"),
      Res_Out => Intern ("out"),
      Res_Package => Intern ("package"),
      Res_Pragma => Intern ("pragma"),
      Res_Private => Intern ("private"),
      Res_Procedure => Intern ("procedure"),
      Res_Raise => Intern ("raise"),
      Res_Range => Intern ("range"),
      Res_Record => Intern ("record"),
      Res_Rem => Intern ("rem"),
      Res_Renames => Intern ("renames"),
      Res_Return => Intern ("return"),
      Res_Reverse => Intern ("reverse"),
      Res_Select => Intern ("select"),
      Res_Separate => Intern ("separate"),
      Res_Subtype => Intern ("subtype"),
      Res_Task => Intern ("task"),
      Res_Terminate => Intern ("terminate"),
      Res_Then => Intern ("then"),
      Res_Type => Intern ("type"),
      Res_Use => Intern ("use"),
      Res_When => Intern ("when"),
      Res_While => Intern ("while"),
      Res_With => Intern ("with"),
      Res_Xor => Intern ("xor"),

      --  Ada 95 reserved words

      Res_Abstract => Intern ("abstract"),
      Res_Aliased => Intern ("aliased"),
      Res_Protected => Intern ("protected"),
      Res_Until => Intern ("until"),
      Res_Requeue => Intern ("requeue"),
      Res_Tagged => Intern ("tagged"),

      --  Ada 2005 reserved words

      Res_Interface => Intern ("interface"),
      Res_Overriding => Intern ("overriding"),
      Res_Synchronized => Intern ("synchronized"),

      --  Ada 2012 reserved words

      Res_Some => Intern ("some")
     ); -- Token_To_Symbol_Map

   function Lookup_Reserved_Word
     (Text : Symbol; Ada_Version : Ada_Version_Type)
      return Reserved_Word_Or_Id;
   --  If Text is a reserved word for the given Ada_Version, return that
   --  Reserved_Word. Otherwise, return Ident.

   ----------------

   procedure Poke_Kind
     (Tok : in out Opt_Token; New_Kind : Reserved_Word);
   --  Does the equivalent of "Tok.Kind := New_Kind;", preserving the value of
   --  the only other relevant component (Sloc).

   type No_Discrim_Token is record
      Kind : Token_Kind;
      Sloc : Source_Location;
   end record;

   procedure Poke_Kind
     (Tok : in out Opt_Token; New_Kind : Reserved_Word)
   is
      --  We're trying to set Tok.Kind, but discriminants are constant, so
      --  "Tok.Kind := New_Kind;" would be illegal. It would also make sense to
      --  use an aggregate, as in "Tok := (Kind => New_Kind, ...);", but that
      --  also would be illegal. So we cheat, using an unchecked conversion.
      --  The alternative would be an annoyingly-long, error-prone case
      --  statement.
      function Cast is new Unchecked_Conversion (No_Discrim_Token, Token);
   begin
      Tok := Cast (No_Discrim_Token'(Kind => New_Kind, Sloc => Tok.Sloc));
   end Poke_Kind;

   function Text (X : Same_Text_Kind) return Syms.Symbol is
     (Token_To_Symbol_Map (X));

   function Text (X : Token) return Syms.Symbol is
   begin
      case X.Kind is
         when Same_Text_Kind => return Text (X.Kind);
         when Stored_Text_Kind => return X.Text;
         when Nil => raise Program_Error;
      end case;
   end Text;

   function Line_Length
     (Input    : in out Buffer;
      Ends     : Marker_Vector;
      Line_Num : Positive)
      return     Natural
   is

      M1 : constant Marker   := Ends (Marker_Index (Line_Num));
      P1 : constant Positive := Position (Input, M1);
      M0 : Marker;
      P0 : Natural;

   begin
      if Line_Num = 1 then
         P0 := 0;
      else
         M0 := Ends (Marker_Index (Line_Num - 1));
         P0 := Position (Input, M0);
      end if;
      return P1 - P0 - 1;
   end Line_Length;

   ----------------

   package Symbol_Encodings is new Encodings (Symbol);
   package Natural_Encodings is new Encodings (Natural);
   use Fixed_Part_Vectors, Octet_Vectors, Symbol_Encodings, Natural_Encodings;

   function Kind (X : Tokn_Cursor) return Token_Kind is
   begin
      pragma Assert (not After_Last (X));
      return X.V.Fixed (X.Fi).Kind;
   end Kind;

   procedure Set_Tokn_Kind (X : Tokn_Cursor; K : Token_Kind) is
      pragma Assert (Kind (X) = Blank_Line);
      pragma Assert (K = True_End_Of_Line);
      --  Above is the only supported scenario, for now. This lets us avoid
      --  worrying about Octets.

      --  The following is a bit of a cheat, but it allows us to keep the V
      --  discriminant "access constant", which is desirable elsewhere.
      type Access_Variable_Tokn_Vec is access all Tokn_Vec;
   begin
      Access_Variable_Tokn_Vec'(X.V.all'Unrestricted_Access).Fixed (X.Fi).Kind
        := K;
   end Set_Tokn_Kind;

   function Sloc (X : Tokn_Cursor) return Source_Location is
   begin
      return (Line => Sloc_Line (X),
              Col => Sloc_Col (X),
              First => Sloc_First (X),
              Last => Sloc_Last (X),
              Firstx => X.V.Fixed (X.Fi).Firstx,
              Lastx => X.V.Fixed (X.Fi).Lastx);
   end Sloc;

   function Sloc_Line (X : Tokn_Cursor) return Positive is
   begin
      return X.V.Fixed (X.Fi).Sloc_Line;
   end Sloc_Line;

   function Sloc_Col (X : Tokn_Cursor) return Positive is
   begin
      return X.V.Fixed (X.Fi).Sloc_Col;
   end Sloc_Col;

   function Sloc_First (X : Tokn_Cursor) return Positive is
   begin
      return X.V.Fixed (X.Fi).Sloc_First;
   end Sloc_First;

   function Sloc_Last (X : Tokn_Cursor) return Natural is
   begin
      return Next_Sloc_First (X) - 1;
   end Sloc_Last;

   function New_Sloc_First (V : Tokn_Vec) return Positive is
     (V.New_Sloc_First);

   function Next_Sloc_First (X : Tokn_Cursor) return Positive is
     (if At_Last (X) then New_Sloc_First (X.V.all)
      else Sloc_First (Next (X)));

   function Text (X : Tokn_Cursor) return Symbol is
   begin
      pragma Assert (not After_Last (X));
      case Kind (X) is
         when Same_Text_Kind => return Token_To_Symbol_Map (Kind (X));
         when Stored_Text_Kind => return Decode (X.V.Octets, X.Oc);
      end case;
   end Text;

   function Leading_Blanks (X : Tokn_Cursor) return Natural is
   begin
      return Decode (X.V.Octets, Next (X.V.Octets, X.Oc));
   end Leading_Blanks;

   function Width (X : Tokn_Cursor) return Positive is
   begin
      return Decode (X.V.Octets, Next (X.V.Octets, Next (X.V.Octets, X.Oc)));
   end Width;

   function Num_Lines (X : Tokn_Cursor) return Positive is
     (Decode (X.V.Octets,
              Next (X.V.Octets,
                    Next (X.V.Octets,
                          Next (X.V.Octets, X.Oc))))) with
       Pre => Kind (X) in Whole_Line_Comment;

   function Last_Line_Len (X : Tokn_Cursor) return Positive is
     (Decode (X.V.Octets,
              Next (X.V.Octets,
                    Next (X.V.Octets,
                          Next (X.V.Octets,
                                Next (X.V.Octets, X.Oc)))))) with
       Pre => Kind (X) in Whole_Line_Comment;
   function Token_Output_Len (X : Token) return Positive is
      Text_Len : constant Natural := To_W_Str (X.Text)'Length;
      L : constant Positive :=
        (if X.Kind in Whole_Line_Comment then X.Num_Lines else 1);
        --  Number of lines in comment
   begin
      return
        L * (String'("--")'Length + X.Leading_Blanks)
        --  Each line is missing the "--  ".
        + (L - 1) * (X.Sloc.Col - 1)
        --  All but the first line are missing the spaces before "--".
        + Text_Len -- Text includes the intermediate NL characters
        - 1 -- for the extra NL at the end
        ;
   end Token_Output_Len;

   function Token_Output_Len (X : Tokn_Cursor) return Positive is
     (Token_Output_Len (Token_At_Cursor (X)));

   procedure Clear (V : in out Tokn_Vec) is
   begin
      pragma Assert (not V.Frozen);
      V.New_Sloc_First := 1;
      Clear (V.Fixed);
      Clear (V.Octets);
   end Clear;

   function Length (X : Token) return Natural is
     (X.Sloc.Last - X.Sloc.First + 1);

   procedure Append_Tokn (V : in out Tokn_Vec; X : Token;
                          Org : String := "Append Token");

   procedure Append_Tokn (V : in out Tokn_Vec; X : Token;
                          Org : String := "Append Token") is
      pragma Assert (not V.Frozen);

      --  We require that X.Sloc.First and X.Sloc.Last indicate the right
      --  length, although they don't have to be right. X.Last_Line_Len must be
      --  correct, and X.Sloc.Col for whole-line comments. The other fields of
      --  X.Sloc can be wrong, and are recomputed here.

      K : constant Token_Kind := X.Kind;

      Ignored_Prev : Opt_Token;
      --  For debugging and assertions
      procedure Debug_Token;
      procedure Debug_Token is
         Text_Len : constant Natural := To_W_Str (Text (X))'Length;
      begin
         if not Is_Empty (V) then
            declare
               P : constant Tokn_Cursor := Last (V'Unrestricted_Access);
            begin
               Ignored_Prev := Token_At_Cursor (P);

               if Kind (P) = Spaces then
                  pragma Assert (K not in End_Of_Line | Blank_Line | Spaces);
               end if;
               if Kind (P) in End_Of_Line | Blank_Line then
                  pragma Assert (K not in End_Of_Line);
               end if;
               if Kind (P) in Comment_Kind then
                  pragma Assert (K in End_Of_Line);
               end if;
            end;
         end if;

         pragma Assert
           (if K not in End_Of_Line | Blank_Line | Comment_Kind then
              Length (X) = Text_Len);
         pragma Assert
           (if K in True_End_Of_Line | Blank_Line then
              Length (X) in 1 | 2 and then Text_Len = 1);
         --  2 is for CR/LF
         if K in Comment_Kind then
            declare
               L : constant Positive :=
                 (if K in Whole_Line_Comment then X.Num_Lines else 1);
                 --  Number of lines in comment
               Expected_Len : constant Positive :=
                 L * (String'("--")'Length + X.Leading_Blanks)
                 --  Each line is missing the "--  ".
                 + (L - 1) * (X.Sloc.Col - 1)
                 --  All but the first line are missing the spaces before "--".
                 + Text_Len -- Text includes the intermediate NL characters
                 - 1 -- for the extra NL at the end
                 ;
            begin
               pragma Assert
                 (Length (X) in Expected_Len | Expected_Len + (L - 1));
               --  The (L - 1) is in case the source has CRLF line endings;
               --  Text does not include the intermediate CR characters.
            end;
         end if;
      end Debug_Token;
      pragma Debug (Debug_Token);

      function Get_Sloc return Source_Location;
      --  Compute the Sloc of X, based on X.Sloc.First and X.Sloc.Last, and on
      --  the Sloc of the previous token.

      function Get_Sloc return Source_Location is
      begin
         return Result : Source_Location do
            if Is_Empty (V) then
               Result := (Line => 1, Col => 1, First => 1, Last => 0,
                          Firstx | Lastx => <>);
            else
               declare
                  Prev : constant Tokn_Cursor := Last (V'Unrestricted_Access);
                  pragma Assert (if K = Spaces then Kind (Prev) /= Spaces);
                  --  We don't want two Spaces tokens in a row
                  Prev_Sloc : constant Source_Location := Sloc (Prev);
               begin
                  if Kind (Prev) in End_Of_Line | Blank_Line then
                     Result.Line := Prev_Sloc.Line + 1;
                     Result.Col := 1;
                  elsif Kind (Prev) in Whole_Line_Comment then
                     pragma Assert (K in End_Of_Line);
                     Result.Line :=
                       Prev_Sloc.Line + Num_Lines (Prev) - 1;
                     Result.Col := Prev_Sloc.Col + Last_Line_Len (Prev);
                  else
                     Result.Line := Prev_Sloc.Line;
                     Result.Col := Prev_Sloc.Col +
                       Prev_Sloc.Last - Prev_Sloc.First + 1;
                  end if;

                  Result.First := Prev_Sloc.Last + 1;
                  Result.Last := Prev_Sloc.Last + Length (X);
               end;
            end if;

            Result.Firstx := X.Sloc.Firstx;
            Result.Lastx := X.Sloc.Lastx;
         end return;
      end Get_Sloc;

      Sloc : constant Source_Location := Get_Sloc;

   begin
      V.New_Sloc_First := Sloc.Last + 1;
      Append (V.Fixed,
              Fixed_Part'(K,
                          Sloc_Line => Sloc.Line,
                          Sloc_Col => Sloc.Col,
                          Sloc_First => Sloc.First,
                          Firstx => Sloc.Firstx,
                          Lastx => Sloc.Lastx,
                          Origin => Intern (Org)));
      if K in Stored_Text_Kind then
         Encode (V.Octets, X.Text);

         if K in Comment_Kind then
            Encode (V.Octets, X.Leading_Blanks);

            if K in Whole_Line_Comment then
               Encode (V.Octets, X.Width);
               Encode (V.Octets, X.Num_Lines);
               Encode (V.Octets, X.Last_Line_Len);
            end if;
         end if;
      end if;
   end Append_Tokn;

   procedure Append_Tokn (V : in out Tokn_Vec; X : Tokn_Cursor;
                          Org : String := "Append Tokn_Cursor") is
   begin
      --  ????It would be more efficient to simply copy over the data, and
      --  avoid converting back to type Token. Also below.
      Append_Tokn (V, Token_At_Cursor (X), Org);
   end Append_Tokn;

   procedure Append_Tokn (V : in out Tokn_Vec; X : Same_Text_Kind;
                          Org : String := "Append Kind")
   is
      Tok : Token (Kind => X);
   begin
      Tok.Sloc :=
        (First => 1, Last => Str (Text (X)).Length, others => <>);
      --  There are never any wide characters in these tokens, so the above
      --  Length is correct.
      Append_Tokn (V, Tok, Org);
   end Append_Tokn;

   procedure Append_Tokn
     (V : in out Tokn_Vec; X : Stored_Text_Kind; Tx : Syms.Symbol;
      Org : String := "Append Kind&Text")
   is
      Tok : Token (Kind => X);
   begin
      pragma Assert (Str (Tx).Length > 0);
      Tok.Sloc :=
        (First => 1, Last => To_W_Str (Tx)'Length, others => <>);
      --  ????We should store all text in UTF-8, so we don't have to do the
      --  conversion to wide string here and elsewhere. It would be more
      --  efficient to do "Str (Tx).Length".
      Tok.Text := Tx;
      Append_Tokn (V, Tok, Org);
   end Append_Tokn;

   procedure Append_Spaces
     (V : in out Tokn_Vec; Count : Natural;
      Existing_OK : Boolean := False;
      Org : String := "Append_Spaces") is
   begin
      pragma Assert (not Is_Empty (V));
      if Count > 0 then
         if Existing_OK
           and then Kind (Last (V'Unrestricted_Access)) = Spaces
         then
            declare
               L : constant Token := Delete_Last (V);
            begin
               Append_Spaces
                 (V, Count => Str (Text (L)).Length + Count,
                  Org => "NLs/Ind combined space");
            end;
         else
            Append_Tokn (V, Spaces, Intern (String'(1 .. Count => ' ')), Org);
            --  ???For smallish Counts, we could look up the symbol in a table
            --  indexed by Count.
         end if;
      end if;
   end Append_Spaces;

   procedure Append_EOL (V : in out Tokn_Vec; Org : String) is
      P : constant Tokn_Cursor := Last (V'Unrestricted_Access);
   begin
      case Kind (P) is
         when End_Of_Line | Blank_Line =>
            Append_Tokn (V, Blank_Line, Org);
         when others =>
            Append_Tokn (V, True_End_Of_Line, Org);
      end case;
   end Append_EOL;

   procedure Append_Comment (V : in out Tokn_Vec; X : Tokn_Cursor;
                             Org : String) is
      --  X is coming from Src_Tokns, and its length includes the spaces at the
      --  start of every line but the first. But indentation is not present in
      --  Newer_Tokns, so we need to subtract that off.

      Tok : Token := Token_At_Cursor (X);
   begin
      case Comment_Kind'(Tok.Kind) is
         when End_Of_Line_Comment => null;
         when Whole_Line_Comment =>
            pragma Assert (Kind (Last (V'Unrestricted_Access)) /= Spaces);
            Tok.Sloc.Last :=
              Tok.Sloc.Last - (Tok.Num_Lines - 1) * (Tok.Sloc.Col - 1);
            Tok.Sloc.Col := 1;
      end case;
      Append_Tokn (V, Tok, Org);
   end Append_Comment;

   procedure Append_Comment_Text
     (V : in out Tokn_Vec; X : Tokn_Cursor; Tx : W_Str;
      Recompute_Length : Boolean;
      Comments_Only, Comments_Gnat_Beginning : Boolean;
      Indent : Natural := 0; Org : String)
   is
      Tok : Token := Token_At_Cursor (X);
      Line_Width, Max_Line_Width : Natural := 0;
      Prefix_Len : Natural;
   begin
      if Comments_Gnat_Beginning and then Tok.Kind = Fillable_Comment then
         Tok.Leading_Blanks := Natural'Max (Tok.Leading_Blanks, 2);
      end if;
      Prefix_Len := W_Str'("--")'Length + Tok.Leading_Blanks;

      Tok.Text := W_Intern (Tx);
      if not Comments_Only then
         Tok.Sloc.Col := Indent + 1;
      end if;
      case Comment_Kind'(Tok.Kind) is
         when End_Of_Line_Comment => null;
         when Whole_Line_Comment =>
            Tok.Num_Lines := 1;
            for J in Tx'Range loop
               if Tx (J) = NL then
                  Max_Line_Width := Natural'Max (Max_Line_Width, Line_Width);
                  if J = Tx'Last then
                     Tok.Last_Line_Len := Line_Width + Prefix_Len;
                  else
                     Tok.Num_Lines := Tok.Num_Lines + 1;
                  end if;
                  Line_Width := 0;
               else
                  Line_Width := Line_Width + 1;
               end if;
            end loop;
            Tok.Width := Max_Line_Width + Prefix_Len;
            declare
               Text_Len : constant Natural := Tx'Length;
               Expected_Len : constant Positive :=
                 Tok.Num_Lines * (String'("--")'Length + Tok.Leading_Blanks)
                 --  Each line is missing the "--  ".
                 + (Tok.Num_Lines - 1) * (Tok.Sloc.Col - 1)
                 --  All but the first line are missing the spaces before "--".
                 + Text_Len -- Text includes the intermediate NL characters
                 - 1 -- for the extra NL at the end
                 ;
            begin
               if Recompute_Length then
                  Tok.Sloc.First := 1;
                  Tok.Sloc.Last := Expected_Len;
               else
                  pragma Assert (Length (Tok) = Expected_Len);
               end if;
            end;
      end case;
      Append_Tokn (V, Tok, Org);
   end Append_Comment_Text;

   function Delete_Last (V : in out Tokn_Vec) return Token is
      pragma Assert (not V.Frozen);
      L : constant Tokn_Cursor := Last (V'Unrestricted_Access);
      New_New_Sloc_First : constant Positive := Next_Sloc_First (Prev (L));
   begin
      return Result : constant Token := Token_At_Cursor (L) do
         Delete_Last (V.Fixed);

         while L.Oc /= Last_Index (V.Octets) + 1 loop
            Delete_Last (V.Octets);
         end loop;

         V.New_Sloc_First := New_New_Sloc_First;
         pragma Assert (After_Last (L));
      end return;
   end Delete_Last;

   procedure Freeze_Tokns (V : in out Tokn_Vec) is
   begin
      pragma Assert (not V.Frozen);
      V.Frozen := True;
   end Freeze_Tokns;

   procedure Melt_Tokns (V : in out Tokn_Vec) is
   begin
      pragma Assert (V.Frozen);
      V.Frozen := False;
   end Melt_Tokns;

   function Token_At_Cursor (X : Tokn_Cursor) return Token is
   begin
      return Result : Token (Kind => Kind (X)) do
         Result.Sloc := Sloc (X);
         if Result.Kind in Stored_Text_Kind then
            Result.Text := Text (X);

            if Result.Kind in Comment_Kind then
               Result.Leading_Blanks := Leading_Blanks (X);

               if Result.Kind in Whole_Line_Comment then
                  Result.Width := Width (X);
                  Result.Num_Lines := Num_Lines (X);
                  Result.Last_Line_Len := Last_Line_Len (X);

               end if;
            end if;
         end if;
      end return;
   end Token_At_Cursor;

   function First (V : access constant Tokn_Vec) return Tokn_Cursor is
   begin
      return (V, 1, 1);
   end First;

   function Is_Empty (V : Tokn_Vec) return Boolean is
   begin
      return Result : constant Boolean := Is_Empty (V.Fixed) do
         pragma Assert (if Result then V.New_Sloc_First = 1);
         pragma Assert (if Result then Is_Empty (V.Octets));
      end return;
   end Is_Empty;

   function At_Last (Cur : Tokn_Cursor) return Boolean is
   begin
      pragma Assert (not After_Last (Cur));
      return Cur.Fi = Last_Index (Cur.V.Fixed);
   end At_Last;

   function Get_Tokn_Index (Cur : Tokn_Cursor) return Tokn_Index is
   begin
      return Cur.Fi;
   end Get_Tokn_Index;

   function After_Last (Cur : Tokn_Cursor) return Boolean is
   begin
      pragma Warnings (Off, "lower bound check only fails if it is invalid");
      pragma Assert (Cur.Fi in 1 .. Last_Index (Cur.V.Fixed) + 1);
      pragma Assert (Cur.Oc in 1 .. Last_Index (Cur.V.Octets) + 1);
      pragma Warnings (On, "lower bound check only fails if it is invalid");
      return Result : constant Boolean
        := Cur.Fi = Last_Index (Cur.V.Fixed) + 1
      do
         pragma Assert (if Result then Cur.Oc = Last_Index (Cur.V.Octets) + 1);
      end return;
   end After_Last;

   function Next (Cur : Tokn_Cursor) return Tokn_Cursor is
   begin
      return Result : Tokn_Cursor := Cur do
         Next (Result);
      end return;
   end Next;

   procedure Next (Cur : in out Tokn_Cursor) is
   begin
      pragma Assert (not (After_Last (Cur)));
      if Kind (Cur) in Stored_Text_Kind then
         Next (Cur.V.Octets, Cur.Oc);

         if Kind (Cur) in Comment_Kind then
            Next (Cur.V.Octets, Cur.Oc);

            if Kind (Cur) in Whole_Line_Comment then
               Next (Cur.V.Octets, Cur.Oc);
               Next (Cur.V.Octets, Cur.Oc);
               Next (Cur.V.Octets, Cur.Oc);
            end if;
         end if;
      end if;
      Cur.Fi := Cur.Fi + 1;
   end Next;

   function Prev (Cur : Tokn_Cursor) return Tokn_Cursor is
   begin
      return Result : Tokn_Cursor := Cur do
         Prev (Result);
      end return;
   end Prev;

   procedure Prev (Cur : in out Tokn_Cursor) is
   begin
      Cur.Fi := Cur.Fi - 1;
      if Kind (Cur) in Stored_Text_Kind then
         if Kind (Cur) in Comment_Kind then
            if Kind (Cur) in Whole_Line_Comment then
               Prev (Cur.V.Octets, Cur.Oc);
               Prev (Cur.V.Octets, Cur.Oc);
               Prev (Cur.V.Octets, Cur.Oc);
            end if;

            Prev (Cur.V.Octets, Cur.Oc);
         end if;

         Prev (Cur.V.Octets, Cur.Oc);
      end if;
   end Prev;

   function Succ (Cur : Tokn_Cursor; Count : Tokn_Index) return Tokn_Cursor is
   begin
      pragma Assert (not After_Last (Cur));
      return Result : Tokn_Cursor := Cur do
         for J in 1 .. Count loop
            exit when At_Last (Result);
            Next (Result);
         end loop;
      end return;
   end Succ;

   function Pred (Cur : Tokn_Cursor; Count : Tokn_Index) return Tokn_Cursor is
   begin
      return Result : Tokn_Cursor := Cur do
         for J in 1 .. Count loop
            exit when Result.Fi = 1;
            Prev (Result);
         end loop;
      end return;
   end Pred;

   function Next_Lexeme (Cur : Tokn_Cursor) return Tokn_Cursor is
   begin
      return Result : Tokn_Cursor := Next (Cur) do
         while Kind (Result) in Nonlexeme_Kind loop
            Next (Result);
         end loop;
      end return;
   end Next_Lexeme;

   function Prev_Lexeme (Cur : Tokn_Cursor) return Tokn_Cursor is
   begin
      return Result : Tokn_Cursor := Prev (Cur) do
         while Kind (Result) in Nonlexeme_Kind loop
            Prev (Result);
         end loop;
      end return;
   end Prev_Lexeme;

   type Symbol_To_Reserved_Word_Mapping is
     array (Potential_Reserved_Word_Sym) of Reserved_Word_Or_Id;

   function Init_Symbol_To_Reserved_Word_Map
     return Symbol_To_Reserved_Word_Mapping;

   function Init_Symbol_To_Reserved_Word_Map
     return Symbol_To_Reserved_Word_Mapping
   is
   begin
      return R : Symbol_To_Reserved_Word_Mapping := (others => Ident) do
         for Res in Reserved_Word loop
            R (Token_To_Symbol_Map (Res)) := Res;
         end loop;
      end return;
   end Init_Symbol_To_Reserved_Word_Map;

   Symbol_To_Reserved_Word_Map : constant Symbol_To_Reserved_Word_Mapping :=
     Init_Symbol_To_Reserved_Word_Map;

   function Lookup_Reserved_Word
     (Text : Symbol; Ada_Version : Ada_Version_Type)
      return Reserved_Word_Or_Id
   is
      Normalized : constant Symbol := Same_Ignoring_Case (Text);
   begin
      if Normalized in Potential_Reserved_Word_Sym'First ..
        Last_Reserved_For_Ada_Version (Ada_Version)
      then
         return Symbol_To_Reserved_Word_Map (Normalized);
      else
         return Ident;
      end if;
   end Lookup_Reserved_Word;

   function Get_Tokns
     (Input                     : in out Buffer;
      Result                    : out Tokn_Vec;
      Ada_Version               : Ada_Version_Type;
      Max_Tokens                : Tokn_Index := Tokn_Index'Last;
      Line_Ends                 : Marker_Vector_Ptr := null;
      Lang                      : Language := Ada_Lang)
     return Boolean is
   begin
      Get_Tokns (Input, Result, Ada_Version, Max_Tokens, Line_Ends, Lang);
      return True;
   end Get_Tokns;

   procedure Get_Tokns
     (Input                     : in out Buffer;
      Result                    : out Tokn_Vec;
      Ada_Version               : Ada_Version_Type;
      Max_Tokens                : Tokn_Index := Tokn_Index'Last;
      Line_Ends                 : Marker_Vector_Ptr := null;
      Lang                      : Language := Ada_Lang)
   is
      procedure Assert;
      --  Assert that Line_Ends is correct

      pragma Assert
        (if
           Line_Ends /= null
         then
           Char_At (Input, Last_Position (Input)) = NL);

      Cur_Line, Cur_Col : Positive := 1;
      Cur_First         : Positive := 1;

      Name_Buffer : Bounded_Str;
      Name_Len : Natural renames Name_Buffer.Length;

      procedure Get;
      --  Move ahead one character in the input

      procedure Get_Tokn (Tok : out Token; Allow_Short_Fillable : Boolean);
      --  Get one token from the input, and return it in Tok, except that
      --  Tok.Text is not set. Here, Whole_Line_Comment represents a single
      --  comment line; multiple Whole_Line_Comments that may be filled are
      --  combined into a single Whole_Line_Comment after Get_Tokn returns.

      procedure Append_Tok_Text (Tok : Token);
      --  Add the relevant text to the Name_Buffer. For everything but
      --  comments, this is the entire text of the token; for comments, the
      --  initial "--" and leading blanks are ignored, and an extra NL is
      --  added at the end.

      procedure Finish_Token (Tok : in out Token);
      --  Finish constructing the Token by setting Text and checking for
      --  reserved words.

      procedure Append_To_Result (Tok : in out Token);
      --  Append the token onto Result, and set Preceding_Token and
      --  Preceding_Lexeme as appropriate. Special processing for End_Of_Line:
      --  if it follows an End_Of_Line, turn it into a Blank_Line.

      procedure Scan_Decimal_Digit_Chars;
      procedure Scan_Identifier_Chars;

      procedure Scan_String_Literal (Q_Char : W_Char);
      --  Scan out a string literal, where Q_Char is the initial quote
      --  character (either '"' or '%'), taking care of doubled quote
      --  characters.

      procedure Scan_Comment
        (Tok : in out Opt_Token; Allow_Short_Fillable : Boolean);
      --  Cur (Input) is the first '-' of the start of the comment.
      --  Allow_Short_Fillable indicates that we should allow a comment to be
      --  fillable even if it is short. In the inner loop in Get_Tokns where
      --  we are collecting fillable comments into a single comment paragraph,
      --  we set Allow_Short_Fillable to False for the first comment line, and
      --  True for subsequent lines, so only the first line can be "too short".
      --
      --  Tok.Sloc has already been set before calling this.

      procedure Collect_Comment_Paragraph (Tok : in out Token) with
        Pre => Tok.Kind = Fillable_Comment;
      --  Collect series of Fillable_Comment into comment "paragraphs" that
      --  will be filled if the appropriate command-line option was given.

      procedure Append_Tok_Text (Tok : Token) is
         Token_Text_First : constant Positive :=
           (if
              Tok.Kind in Comment_Kind
            then
              Tok.Sloc.First + String'("--")'Length + Tok.Leading_Blanks
            else Tok.Sloc.First);
      begin
         Append (Name_Buffer,
                 To_UTF8 (Slice (Input, Token_Text_First, Tok.Sloc.Last)));
         if Tok.Kind in Comment_Kind then
            Append (Name_Buffer, ASCII.LF);
         end if;
      end Append_Tok_Text;

      procedure Get is
      begin
         Cur_Col := Cur_Col + 1;

         Cur_First := Cur_First + 1;
         --  It's OK for this to be greater than Input'Last; in that case, Cur
         --  will return W_NUL, indicating end-of-input.

         Move_Forward (Input);
      end Get;

      procedure Scan_Decimal_Digit_Chars is
      begin
         while Cur (Input) in '0' .. '9' | '_' loop
            Get;
         end loop;
      end Scan_Decimal_Digit_Chars;

      procedure Scan_Identifier_Chars is
      begin
         loop
            Get;
            exit when not (Is_Letter (Cur (Input))
                             or else Cur (Input) = '_'
                             or else Is_Digit (Cur (Input))
                             or else Is_Mark (Cur (Input)));
         end loop;
      end Scan_Identifier_Chars;

      procedure Scan_String_Literal (Q_Char : W_Char) is
      begin
         loop
            Get;

            pragma Assert (Cur (Input) /= W_NUL);

            if Cur (Input) = Q_Char then
               Get;

               exit when Cur (Input) /= Q_Char;
            end if;
         end loop;
      end Scan_String_Literal;

      Preceding_Lexeme : Lexeme_Kind := Nil;
      Preceding_Token : Opt_Token_Kind := Nil;
      Preceding_Lexeme_Line : Positive := Integer'Last;
      --  These record the preceding token, which is necessary to properly deal
      --  with single quotes and line breaks. Preceding_Lexeme doesn't count
      --  comments and line breaks; Preceding_Token does.

      procedure Scan_Comment
        (Tok : in out Opt_Token; Allow_Short_Fillable : Boolean) is
         function Count_Blanks return Natural;
         --  Skip to next non-blank character, and return the number of blanks
         --  skipped

         procedure Skip_To_EOL;
         --  Move to end of line

         function Count_Blanks return Natural is
         begin
            return Result : Natural := 0 do
               while Is_Space (Cur (Input)) loop
                  Result := Result + 1;
                  Get;
               end loop;
            end return;
         end Count_Blanks;

         procedure Skip_To_EOL is
         begin
            while not Is_Line_Terminator (Cur (Input))
              and then Cur (Input) /= Token_Separator
              and then Cur (Input) /= W_NUL
            loop
               Get;
            end loop;
         end Skip_To_EOL;

         Kind_Of_Comment : Comment_Kind;
         Is_Fillable_Comment : Boolean;

      --  Start of processing for Scan_Comment

      begin
         if Preceding_Lexeme_Line = Cur_Line then
            Kind_Of_Comment := End_Of_Line_Comment;
         else
            Kind_Of_Comment := Other_Whole_Line_Comment;
         end if;
         Get; -- skip '-'
         Get; -- skip '-'

         if Kind_Of_Comment = Other_Whole_Line_Comment
           and then not
             (Is_Letter (Cur (Input))
                or else Is_Digit (Cur (Input))
                or else Is_Space (Cur (Input))
                or else Is_Line_Terminator (Cur (Input))
                or else Cur (Input) = '-')
            --  ???For now, we don't consider "-----" to be special, because
            --  otherwise various comments are messed up.
         then
            Kind_Of_Comment := Special_Comment;
         end if;

         Is_Fillable_Comment := Kind_Of_Comment = Other_Whole_Line_Comment
           and then Is_Space (Cur (Input));
         --  We don't fill comments unless there is at least one leading blank,
         --  because otherwise some special character like "#" could end up at
         --  the start of a line, causing it to turn into a special comment,
         --  thus messing up the Final_Check. Also, for comment lines starting
         --  with "----Blah", we fill as if "--Blah" is the first word.

         declare
            Leading_Blanks : constant Natural := Count_Blanks;
         begin
            --  Don't fill if too many leading blanks
            if Leading_Blanks > 2 then
               Is_Fillable_Comment := False;
            end if;
            Skip_To_EOL;
            --  Don't fill if comment ends with "--" (like a typical copyright
            --  header). Note that this includes the case of an empty comment,
            --  where the initial "--" is immediately followed by NL.
            if Lookback (Input, 2) = '-'
              and then Lookback (Input, 1) = '-'
            then
               Is_Fillable_Comment := False;
            end if;

            --  Check for --pp-off/--pp-on comments
            if Kind_Of_Comment in Other_Whole_Line_Comment | Special_Comment
            then
               declare
                  Comment_Text : constant W_Str :=
                    Slice (Input, Tok.Sloc.First, Cur_First - 1);
               begin
                  if Has_Prefix
                    (Comment_Text, Prefix => Pp_Off_On_Delimiters.Off.all)
                  then
                     Is_Fillable_Comment := False;
                     Kind_Of_Comment := Pp_Off_Comment;
                  elsif Has_Prefix
                    (Comment_Text, Prefix => Pp_Off_On_Delimiters.On.all)
                  then
                     Is_Fillable_Comment := False;
                     Kind_Of_Comment := Pp_On_Comment;
                  end if;
               end;
            end if;

            declare
               W : constant Natural := Cur_First - Tok.Sloc.First;
               Too_Short : constant Boolean := W < 30;
               --  The comment is too short to be considered as the start of a
               --  filled comment block.
            begin
               if Is_Fillable_Comment
                 and then not Allow_Short_Fillable
                 and then Too_Short
               then
                  Is_Fillable_Comment := False;
               end if;

               if Is_Fillable_Comment then
                  pragma Assert (Kind_Of_Comment = Other_Whole_Line_Comment);
                  Kind_Of_Comment := Fillable_Comment;
               end if;

               case Kind_Of_Comment is
                  when Pp_Off_Comment =>
                     Tok := (Pp_Off_Comment,
                             Tok.Sloc,
                             Text => Intern ("invalid token text"),
                             Leading_Blanks => Leading_Blanks, Width => W,
                             Num_Lines => 1,
                             Last_Line_Len => Cur_Col - Tok.Sloc.Col);
                  when Pp_On_Comment =>
                     Tok := (Pp_On_Comment,
                             Tok.Sloc,
                             Text => Intern ("invalid token text"),
                             Leading_Blanks => Leading_Blanks, Width => W,
                             Num_Lines => 1,
                             Last_Line_Len => Cur_Col - Tok.Sloc.Col);
                  when Special_Comment =>
                     Tok := (Special_Comment,
                             Tok.Sloc,
                             Text => Intern ("invalid token text"),
                             Leading_Blanks => Leading_Blanks, Width => W,
                             Num_Lines => 1,
                             Last_Line_Len => Cur_Col - Tok.Sloc.Col);
                  when Fillable_Comment =>
                     Tok := (Fillable_Comment,
                             Tok.Sloc,
                             Text => Intern ("invalid token text"),
                             Leading_Blanks => Leading_Blanks, Width => W,
                             Num_Lines => 1,
                             Last_Line_Len => Cur_Col - Tok.Sloc.Col);
                  when Other_Whole_Line_Comment =>
                     Tok := (Other_Whole_Line_Comment,
                             Tok.Sloc,
                             Text => Intern ("invalid token text"),
                             Leading_Blanks => Leading_Blanks, Width => W,
                             Num_Lines => 1,
                             Last_Line_Len => Cur_Col - Tok.Sloc.Col);
                  when End_Of_Line_Comment =>
                     Tok := (End_Of_Line_Comment,
                             Tok.Sloc,
                             Text => Intern ("invalid token text"),
                             Leading_Blanks => Leading_Blanks);
               end case;
            end;
         end;
      end Scan_Comment;

      procedure Get_Tokn (Tok : out Token; Allow_Short_Fillable : Boolean) is
      begin
         while Cur (Input) = Token_Separator loop
            Get;
         end loop;

         Tok.Sloc :=
           (Line   => Cur_Line,
            Col    => Cur_Col,
            First  => Cur_First,
            Last   => <>,
            Firstx => Mark (Input, '<'),
            Lastx  => <>);

         --  end of line

         if Is_Line_Terminator (Cur (Input)) then
            if Line_Ends /= null then
               Append (Line_Ends.all, Tok.Sloc.Firstx);
            end if;

            if Cur (Input) = W_CR and then Lookahead (Input) = W_LF then
               pragma Assert (Line_Ends = null);
               Get;
            end if;

            Get;
            Tok := (Kind => True_End_Of_Line, Sloc => Tok.Sloc);
            --  Might be ignored below, or turned into Blank_Line

            Cur_Line := Cur_Line + 1;
            Cur_Col  := 1;

         --  Spaces

         elsif Is_Space (Cur (Input)) then
            Tok := (Kind => Spaces, Sloc => Tok.Sloc, Text => <>);
            while Is_Space (Cur (Input)) loop
               Get;
            end loop;

         --  identifier

         --  We allow '$' at the start of an identifier because that's what
         --  preprocessor symbols look like, and this allows us to process some
         --  files that use preprocessing.

         elsif Is_Letter (Cur (Input)) or else
           (Lang = Ada_Lang and then Cur (Input) = '$')
         then
            Tok := (Kind => Ident, Sloc => Tok.Sloc, Text => <>);
            --  We will check for reserved words below
            Scan_Identifier_Chars;

         else
            case Cur (Input) is
               when W_NUL =>
                  Tok := (Kind => End_Of_Input, Sloc => Tok.Sloc);

               --  Minus sign or comment

               when '-' =>
                  if Lookahead (Input) = '-' then
                     Scan_Comment (Tok, Allow_Short_Fillable);
                  else
                     Get;
                     Tok := (Kind => '-', Sloc => Tok.Sloc);
                  end if;

               --  numeric literal

               when '0' .. '9' =>
                  Tok := (Kind => Numeric_Literal,
                          Sloc => Tok.Sloc, others => <>);
                  Scan_Decimal_Digit_Chars;

                  case Lang is
                     when Template_Lang => null; -- we're done
                     when Ada_Lang =>
                        if Cur (Input) in '#' | ':' then
                           loop
                              Get;

                              pragma Assert (Cur (Input) /= W_NUL);
                              exit when Cur (Input) in '#' | ':';
                           end loop;

                           Get;

                        elsif Cur (Input) = '.' then
                           if Lookahead (Input) /= '.' then -- could be ".."
                              Get;
                              Scan_Decimal_Digit_Chars;
                           end if;
                        end if;

                        if To_Lower (Cur (Input)) = 'e' then
                           Get;

                           if Cur (Input) in '+' | '-' then
                              Get;
                           end if;

                           Scan_Decimal_Digit_Chars;
                        end if;
                  end case;

               --  single quote or character literal

               when ''' =>
                  Get;

                  --  We distinguish a single quote token from a character
                  --  literal by looking back at the preceding token. If it's
                  --  not one of the following, then it's a single quote. For
                  --  example, in Character'('''), the first quote follows
                  --  an identifier, so it's a single quote. The second one
                  --  follows a left parenthesis, so it's the start of a
                  --  character literal. The String_Literal case is really
                  --  for operator symbols, as in "+"'Address.
                  --
                  --  The '!' case is for when we're processing a template
                  --  (for an attribute reference or a qualified expression),
                  --  as opposed to Ada code.

                  if Preceding_Lexeme in Ident | String_Lit |
                      Res_Access | Res_All | ')' | '!'
                  then -- it's a tick
                     pragma Assert
                       (if Preceding_Lexeme = '!' then Lang = Template_Lang);
                     Tok := (Kind => ''', Sloc => Tok.Sloc);
                  else -- it's a character literal
                     Tok := (Kind => Character_Literal,
                             Sloc => Tok.Sloc, others => <>);
                     Get;
                     pragma Assert (Cur (Input) = ''');
                     Get;
                  end if;

               --  string literal

               when '"' | '%' =>
                  Tok := (Kind => String_Lit,
                          Sloc => Tok.Sloc, others => <>);
                  Scan_String_Literal (Q_Char => Cur (Input));

               --  One-character tokens

               when '!' =>
                  Tok := (Kind => '!', Sloc => Tok.Sloc);
                  Get;
               when '#' =>
                  Tok := (Kind => '#', Sloc => Tok.Sloc);
                  Get;
               when '$' =>
                  Tok := (Kind => '$', Sloc => Tok.Sloc);
                  Get;
               when '?' =>
                  Tok := (Kind => '?', Sloc => Tok.Sloc);
                  Get;
               when '[' =>
                  Tok := (Kind => '[', Sloc => Tok.Sloc);
                  Get;
               when '\' =>
                  Tok := (Kind => '\', Sloc => Tok.Sloc);
                  Get;
               when ']' =>
                  Tok := (Kind => ']', Sloc => Tok.Sloc);
                  Get;
               when '^' =>
                  Tok := (Kind => '^', Sloc => Tok.Sloc);
                  Get;
               when '`' =>
                  Tok := (Kind => '`', Sloc => Tok.Sloc);
                  Get;
               when '{' =>
                  Tok := (Kind => '{', Sloc => Tok.Sloc);
                  Get;
               when '}' =>
                  Tok := (Kind => '}', Sloc => Tok.Sloc);
                  Get;
               when '~' =>
                  Tok := (Kind => '~', Sloc => Tok.Sloc);
                  Get;

               when '&' =>
                  Tok := (Kind => '&', Sloc => Tok.Sloc);
                  Get;
               when '(' =>
                  Tok := (Kind => '(', Sloc => Tok.Sloc);
                  Get;
               when ')' =>
                  Tok := (Kind => ')', Sloc => Tok.Sloc);
                  Get;
               when '+' =>
                  Tok := (Kind => '+', Sloc => Tok.Sloc);
                  Get;
               when ',' =>
                  Tok := (Kind => ',', Sloc => Tok.Sloc);
                  Get;
               when ';' =>
                  Tok := (Kind => ';', Sloc => Tok.Sloc);
                  Get;
               when '|' =>
                  Tok := (Kind => '|', Sloc => Tok.Sloc);
                  Get;
               when '@' =>
                  --  '@' is for target_name (see RM-5.2.1, AI12-0125-3)
                  Tok := (Kind => '@', Sloc => Tok.Sloc);
                  Get;

               --  Multiple-character tokens. We need to distinguish between
               --  "=" and "=>", and between "." and ".." and so forth.

               when '=' =>
                  Get;

                  if Cur (Input) = '>' then
                     Tok := (Kind => Arrow, Sloc => Tok.Sloc);
                     Get;
                  else
                     Tok := (Kind => '=', Sloc => Tok.Sloc);
                  end if;

               when '.' =>
                  Get;

                  if Cur (Input) = '.' then
                     Tok := (Kind => Dot_Dot, Sloc => Tok.Sloc);
                     Get;
                  else
                     Tok := (Kind => '.', Sloc => Tok.Sloc);
                  end if;

               when '*' =>
                  Get;

                  if Cur (Input) = '*' then
                     Tok := (Kind => Exp_Op, Sloc => Tok.Sloc);
                     Get;
                  else
                     Tok := (Kind => '*', Sloc => Tok.Sloc);
                  end if;

               when '/' =>
                  Get;

                  if Cur (Input) = '=' then
                     Tok := (Kind => Not_Equal, Sloc => Tok.Sloc);
                     Get;
                  else
                     Tok := (Kind => '/', Sloc => Tok.Sloc);
                  end if;

               when '>' =>
                  Get;

                  if Cur (Input) = '=' then
                     Tok := (Kind => Greater_Or_Equal, Sloc => Tok.Sloc);
                     Get;
                  elsif Cur (Input) = '>' then
                     Tok := (Kind => Right_Label_Bracket, Sloc => Tok.Sloc);
                     Get;
                  else
                     Tok := (Kind => '>', Sloc => Tok.Sloc);
                  end if;

               when '<' =>
                  Get;

                  if Cur (Input) = '=' then
                     Tok := (Kind => Less_Or_Equal, Sloc => Tok.Sloc);
                     Get;
                  elsif Cur (Input) = '<' then
                     Tok := (Kind => Left_Label_Bracket, Sloc => Tok.Sloc);
                     Get;
                  elsif Cur (Input) = '>' then
                     Tok := (Kind => Box, Sloc => Tok.Sloc);
                     Get;
                  else
                     Tok := (Kind => '<', Sloc => Tok.Sloc);
                  end if;

               when ':' =>
                  Get;

                  if Cur (Input) = '=' then
                     Tok := (Kind => Colon_Equal, Sloc => Tok.Sloc);
                     Get;
                  else
                     Tok := (Kind => ':', Sloc => Tok.Sloc);
                  end if;

               when others =>
                  Text_IO.Put_Line
                    (Text_IO.Standard_Error,
                     "illegal character: " & To_UTF8 ((1 => Cur (Input))));
                  if Cur (Input) = '#' then
                     Text_IO.Put_Line
                       (Text_IO.Standard_Error, "preprocessing not supported");
                  end if;
                  raise Program_Error;
                  --  All legal token-starting characters are handled above
            end case;
         end if;

         Tok.Sloc.Lastx := Mark (Input, '>');
         Tok.Sloc.Last  := Cur_First - 1;
         pragma Assert (if Tok.Kind in Whole_Line_Comment then
           Tok.Width = Tok.Sloc.Last - Tok.Sloc.First + 1);

         pragma Assert (Tok.Kind /= Nil);
      end Get_Tokn;

      procedure Finish_Token (Tok : in out Token) is
      begin
         pragma Assert (Name_Len = 0);
         Append_Tok_Text (Tok);
         declare
            Tok_Text : constant Symbol := Intern (Name_Buffer);
         begin
            case Tok.Kind is
               when Comment_Kind =>
                  pragma Assert (False);

               when Ident =>
                  --  Check for reserved word. In T'Range, we consider "Range"
                  --  to be an identifier, not a reserved word, and similarly
                  --  for others.

                  if Preceding_Lexeme /= ''' then
                     declare
                        RW : constant Reserved_Word_Or_Id :=
                          Lookup_Reserved_Word (Tok_Text, Ada_Version);
                        Old_Sloc : constant Source_Location := Tok.Sloc;
                     begin
                        case RW is
                           when Reserved_Word =>
                              Poke_Kind (Tok, New_Kind => RW);
                           when Ident => null;
                        end case;

                        pragma Assert (Tok.Kind = RW);
                        pragma Assert (Tok.Sloc = Old_Sloc);
                     end;
                  end if;

               when others =>
                  null;
            end case;
            if Tok.Kind in Stored_Text_Kind then
               Tok.Text := Tok_Text;
            end if;
         end;
      end Finish_Token;

      procedure Append_To_Result (Tok : in out Token) is
      begin
         if Tok.Kind in End_Of_Line
           and then Preceding_Token in End_Of_Line | Blank_Line
         then
            Tok := (Kind => Blank_Line, Sloc => Tok.Sloc);
         end if;

         Append_Tokn (Result, Tok);

         Preceding_Token := Tok.Kind;
         if Tok.Kind in Lexeme_Kind then
            Preceding_Lexeme := Tok.Kind;
            Preceding_Lexeme_Line := Tok.Sloc.Line;
         end if;

         if Assert_Enabled then
            declare
               Inp : constant W_Str :=
                 Slice (Input, Tok.Sloc.Firstx, Tok.Sloc.Lastx);
               L : constant Tokn_Cursor := Last (Result'Unrestricted_Access);
               Outp : constant W_Str := To_W_Str (Text (L));
            begin
               --  Can't assert for comments because block comments
               pragma Assert
                 (case Tok.Kind is
                    when Comment_Kind => True,
                    when End_Of_Line | Blank_Line =>
                      Inp in (1 => W_LF) | (W_CR, W_LF)
                        | (1 => W_FF) | (1 => W_VT)
                        and then Outp = (1 => NL),
                    when Reserved_Word => To_Lower (Inp) = Outp,
                    when others => Inp = Outp);
            end;
         end if;
      end Append_To_Result;

      Start_Mark_F  : constant Marker := Mark (Input, '!');
      Start_Mark_L  : constant Marker := Mark (Input, '>');
      Start_Token : constant Token  :=
        (Start_Of_Input,
         Sloc =>
           (Line  => Cur_Line,
            Col   => Cur_Col,
            First => Cur_First,
            Last  => 0,
            Firstx => Start_Mark_F,
            Lastx => Start_Mark_L));

      procedure Assert is
      begin
         if Line_Ends /= null then
            for E in 1 .. Last_Index (Line_Ends.all) loop
               pragma Assert
                 (Char_At (Input, Position (Input, Line_Ends.all (E))) = NL);
            end loop;
         end if;
      end Assert;

      procedure Collect_Comment_Paragraph (Tok : in out Token) is
         Tok_EOL, Possible_Spaces, Tok_2 : Opt_Token;
         --  Tok is a Fillable_Comment; it might be the first of a
         --  paragraph. Tok_EOL is the End_Of_Line token that follows the
         --  comment, Possible_Spaces is the spaces on the next line (unless
         --  the Tok_2 is at the start of line), and Tok_2 is the token after
         --  that, which might need to be combined with Tok.

         --  The purpose of the following arcane code is to combine multiple
         --  Fillable_Comments filled into a single Fillable_Comment
         --  "paragraph". Unfillable comments never combine into a
         --  paragraph. All comments in a paragraph must start at the same
         --  column in the input, and must contain the same number of leading
         --  blanks. The first comment of a paragraph cannot be too short;
         --  subsequent lines may be. End_Of_Line_Comments never combine.

         --  For example, if we have the following comments:

         --  xxxxxx xxxxxx xxxxxx xxxxxx xxxxxx xxxxxx xxxxxx xxxxxx
         --  yyyyyy yyyyyy yyyyyy yyyyyy yyyyyy yyyyyy yyyyyy yyyyyy

         --  Then we enter this with Tok = the "xx..." comment.  Tok_EOL will
         --  be the End_Of_Line after that, Possible_Spaces will be the " "
         --  after that, and Tok_2 will be the "yy..." comment. Tok_2 will be
         --  combined with Tok, and we go around the loop again. Now Tok is the
         --  combined comment, Tok_EOL is the End_Of_Line after "yy...",
         --  Possible_Spaces is not used, and Tok_2 is the Blank_Line after
         --  Tok_EOL. Tok_2 is not a fillable comment, so we send Tok, Tok_EOL,
         --  (not Possible_Spaces), and Tok_2 to the output, in that order, and
         --  exit the loop.

         procedure Send_EOL_And_Possible_Spaces;
         --  This is used in the cases where Tok_2 cannot be combined with
         --  Tok. It sends Tok_EOL, and possibly Possible_Spaces, to the
         --  output.

         procedure Send_EOL_And_Possible_Spaces is
         begin
            Name_Len := 0;
            Finish_Token (Tok_EOL);
            Append_To_Result (Tok_EOL);

            if Possible_Spaces.Kind = Spaces then
               Name_Len := 0;
               Finish_Token (Possible_Spaces);
               Append_To_Result (Possible_Spaces);
            end if;
         end Send_EOL_And_Possible_Spaces;

      --  Start of processing for Collect_Comment_Paragraph

      begin
         --  Loop, repeatedly getting Possible_Spaces and Tok_2, and combining
         --  Tok_2 into Tok until something ends the paragraph.

         loop
            Get_Tokn (Tok_EOL, Allow_Short_Fillable => False);
            pragma Assert (Tok_EOL.Kind in End_Of_Line);
            Get_Tokn (Possible_Spaces, Allow_Short_Fillable => True);
            if Possible_Spaces.Kind = Spaces then
               Get_Tokn (Tok_2, Allow_Short_Fillable => True);
            else
               Tok_2 := Possible_Spaces;
            end if;

            if Tok_2.Kind in Whole_Line_Comment then

               --  Unfillable comment breaks the paragraph. Finish constructing
               --  Tok, send it to Result followed by Tok_EOL, Possible_Spaces,
               --  and Tok_2.

               if Tok_2.Kind /= Fillable_Comment then
                  Tok.Text := Intern (Name_Buffer);
                  Append_To_Result (Tok);
                  Send_EOL_And_Possible_Spaces;
                  Name_Len := 0;
                  Append_Tok_Text (Tok_2);
                  Tok_2.Text := Intern (Name_Buffer);
                  Append_To_Result (Tok_2);
                  Tok := Tok_2;
                  exit;

               --  Tok_2 can be combined

               elsif Tok.Sloc.Col = Tok_2.Sloc.Col
                 and then Tok.Leading_Blanks = Tok_2.Leading_Blanks
               then
                  Append_Tok_Text (Tok_2);
                  Tok.Width := Natural'Max (Tok.Width, Tok_2.Width);
                  Tok.Sloc.Last := Tok_2.Sloc.Last;
                  Tok.Sloc.Lastx := Tok_2.Sloc.Lastx;
                  Tok.Num_Lines := Tok.Num_Lines + 1;
                  Tok.Last_Line_Len := Tok_2.Last_Line_Len;
                  --  Go around the loop again, in case the next Tok_2 can be
                  --  combined.

               --  Tok_2 cannot be combined, but it might start a new
               --  paragraph. Finish constructing Tok, send it to Result
               --  followed by Tok_EOL and Possible_Spaces, and use Tok_2 as
               --  the new Tok.

               else
                  Tok.Text := Intern (Name_Buffer);
                  Append_To_Result (Tok);
                  Send_EOL_And_Possible_Spaces;
                  Name_Len := 0;
                  Append_Tok_Text (Tok_2);
                  Tok := Tok_2;
                  --  Go around the loop again, with the new initial line of
                  --  the paragraph in Tok.
               end if;

            --  Not a comment, so cannot be combined. Finish constructing Tok,
            --  send it to Result followed by Tok_EOL, Possible_Spaces, and
            --  Tok_2, then exit.

            else
               pragma Assert (Tok_2.Kind not in Comment_Kind);
               Tok.Text := Intern (Name_Buffer);
               Append_To_Result (Tok);
               Send_EOL_And_Possible_Spaces;
               Name_Len := 0;
               Finish_Token (Tok_2);
               Append_To_Result (Tok_2);
               Tok := Tok_2;
               exit;
            end if;
         end loop;
      end Collect_Comment_Paragraph;

   --  Start of processing for Get_Tokns

   begin
      pragma Assert (Point (Input) = 1);
      Clear (Result);
      Append_Tokn (Result, Start_Token);

      if Line_Ends /= null then
         Clear (Line_Ends.all);
      end if;

      loop
         if Result.Fixed.Last_Index - 1 = Max_Tokens then
            --  "- 1" because Start_Of_Input doesn't count
            while not At_End (Input) loop
               Move_Forward (Input);
            end loop;
            exit;
         end if;

         Name_Len := 0;

         declare
            Tok : Opt_Token;
         begin
            Get_Tokn (Tok, Allow_Short_Fillable => False);
            Error_Sloc := To_Langkit (Tok.Sloc);
            if Tok.Kind in Comment_Kind then
               Append_Tok_Text (Tok);
               if Tok.Kind = Fillable_Comment then
                  Collect_Comment_Paragraph (Tok);
               else
                  Tok.Text := Intern (Name_Buffer);
                  Append_To_Result (Tok);
               end if;

            --  The simple case: Tok is not a comment, so just finish
            --  constructing it and send it to Result.

            else
               pragma Assert (Tok.Kind not in Comment_Kind);
               Finish_Token (Tok);
               Append_To_Result (Tok);
            end if;

            exit when Tok.Kind = End_Of_Input;
         end;
      end loop;

      pragma Debug (Assert);
      Reset (Input);
   end Get_Tokns;

   procedure Move_Tokns (Target, Source : in out Tokn_Vec) is
   begin
      pragma Assert (not Target.Frozen);
      pragma Assert (not Source.Frozen);
      Target.New_Sloc_First := Source.New_Sloc_First;
      Source.New_Sloc_First := 1;
      Move (Target.Fixed, Source.Fixed);
      Move (Target.Octets, Source.Octets);
   end Move_Tokns;

   function Same_Token (X, Y : Token) return Boolean is
      YY : Token := Y;
   begin
      --  Ignore these parts in the comparison:
      YY.Sloc.Firstx := X.Sloc.Firstx;
      YY.Sloc.Lastx := X.Sloc.Lastx;

      --  Filling can cause a comment to shrink, which makes it unfillable:

      if X.Kind = Fillable_Comment
        and then YY.Kind = Other_Whole_Line_Comment
      then
         YY := (Fillable_Comment, YY.Sloc,
                Text => YY.Text, Leading_Blanks => YY.Leading_Blanks,
                Width => YY.Width, Num_Lines => YY.Num_Lines,
                Last_Line_Len => YY.Last_Line_Len);
      elsif X.Kind = Other_Whole_Line_Comment
        and then YY.Kind = Fillable_Comment
      then
         YY := (Other_Whole_Line_Comment, YY.Sloc,
                Text => YY.Text, Leading_Blanks => YY.Leading_Blanks,
                Width => YY.Width, Num_Lines => YY.Num_Lines,
                Last_Line_Len => YY.Last_Line_Len);
      end if;

      return X = YY;
   end Same_Token;

   procedure Check_Same_Token
     (X, Y : Tokn_Cursor;
      Message, Name_1, Name_2 : String)
   is
      XX : constant Token := Token_At_Cursor (X);
      YY : constant Token := Token_At_Cursor (Y);
   begin
      if not Same_Token (XX, YY) then
         Text_IO.Put_Line
           (Text_IO.Standard_Output, Message & ": Tokens differ:");
         if Debug.Debug_Flag_3 then
            Text_IO.Put_Line (Text_IO.Standard_Output, Name_1 & " =");
            Put_Tokens (X.V.all);
            Text_IO.Put_Line (Text_IO.Standard_Output, Name_2 & " =");
            Put_Tokens (Y.V.all);
            Show_Origin := True;
            Text_IO.Put_Line (Text_IO.Standard_Output, "With Origins:");
            Text_IO.Put_Line (Text_IO.Standard_Output, Name_1 & " =");
            Put_Tokens (X.V.all);
            Text_IO.Put_Line (Text_IO.Standard_Output, Name_2 & " =");
            Put_Tokens (Y.V.all);
         end if;
         Show_Origin := True;
         Text_IO.Put_Line (Text_IO.Standard_Output, Name_1 & " =");
         Put_Token (X);
         Text_IO.Put_Line (Text_IO.Standard_Output, Name_2 & " =");
         Put_Token (Y);
         raise Program_Error;
      end if;

      pragma Assert
        (if XX.Kind not in Comment_Kind then
           Length (XX) = To_W_Str (Text (XX))'Length);
   end Check_Same_Token;

   procedure Check_Same_Tokens
     (X, Y : Tokn_Vec; Message, Name_1, Name_2 : String)
   is
      pragma Assert (not Is_Empty (X));
      pragma Assert (not Is_Empty (Y));
      Xj : Tokn_Cursor := First (X'Unrestricted_Access);
      Yj : Tokn_Cursor := First (Y'Unrestricted_Access);
      First_Time : Boolean := True;
   begin
      loop
         declare
            X_Tok  : constant Token   := Token_At_Cursor (Xj);
            Y_Tok  : constant Token   := Token_At_Cursor (Yj);
            X_Done : constant Boolean := X_Tok.Kind = End_Of_Input;
            Y_Done : constant Boolean := Y_Tok.Kind = End_Of_Input;
         begin
            if First_Time then
               First_Time := False;
               pragma Assert (X_Tok.Kind = Start_Of_Input);
               pragma Assert (Y_Tok.Kind = Start_Of_Input);
            end if;

            Check_Same_Token (Xj, Yj, Message, Name_1, Name_2);

            pragma Assert (X_Done = At_Last (Xj));
            pragma Assert (Y_Done = At_Last (Yj));
            pragma Assert (X_Done = Y_Done);
            exit when X_Done;

            Next (Xj);
            Next (Yj);
         end;
      end loop;
   end Check_Same_Tokens;

   procedure Put_Token (Tok : Tokn_Cursor) is
   begin
      if Kind (Tok) in Comment_Kind then
         Text_IO.Put
           (Text_IO.Standard_Output,
            "--" & (1 .. Leading_Blanks (Tok) => ' '));
      end if;
      for C of Str (Text (Tok)).S loop
         if Kind (Tok) in Comment_Kind and then C = ASCII.LF then
            Text_IO.Put (Text_IO.Standard_Output, "$");
         else
            Text_IO.Put (Text_IO.Standard_Output, C);
         end if;
      end loop;
      Text_IO.Put
        (Text_IO.Standard_Output,
         " -- #" &
         Image (Integer (Get_Tokn_Index (Tok))) &
         "  " &
         Capitalize (Kind (Tok)'Img) &
         " at " &
         Image (Sloc (Tok)));
      if Kind (Tok) in Comment_Kind | Spaces
        or else Tokn_Length (Tok) > 2
      then
         Text_IO.Put
           (Text_IO.Standard_Output, " len = " & Image (Tokn_Length (Tok)));
      end if;
      if Kind (Tok) in Whole_Line_Comment then
         Text_IO.Put
           (Text_IO.Standard_Output,
            ", width = " & Image (Width (Tok)) &
            ", " & Image (Num_Lines (Tok)) & " lines" &
            ", lll = " & Image (Last_Line_Len (Tok)));
      end if;
      if Show_Origin then
         Text_IO.Put (Text_IO.Standard_Output, ", origin = """ &
                        Str (Tok.V.Fixed (Tok.Fi).Origin).S & """");
      end if;
      Text_IO.Put_Line (Text_IO.Standard_Output, "");
   end Put_Token;

   procedure Put_Tokens
     (First     : Tokn_Cursor;
      After_Last : Tokn_Cursor;
      Highlight : Tokn_Cursor)
   is
      Tok : Tokn_Cursor := First;
   begin
      while Tok /= After_Last loop
         if Tok = Highlight then
            Text_IO.Put_Line (Text_IO.Standard_Output, "----------------");
         end if;

         Put_Token (Tok);
         Next (Tok);
      end loop;
      Text_IO.Put_Line
        (Text_IO.Standard_Output,
         "New_Sloc_First = " & First.V.New_Sloc_First'Img);
   end Put_Tokens;

   function Last (V : access constant Tokn_Vec) return Tokn_Cursor is
   begin
      return Result : Tokn_Cursor :=
        (V, Last_Index (V.Fixed) + 1, Last_Index (V.Octets) + 1)
      do
         pragma Assert (After_Last (Result));
         Prev (Result);
         pragma Assert (At_Last (Result));
      end return;
   end Last;

   procedure Put_Tokens (Tokens : Tokn_Vec) is
   begin
      if Is_Empty (Tokens) then
         Text_IO.Put_Line (Text_IO.Standard_Output, "empty tokens");
      else
         declare
            F : constant Tokn_Cursor := First (Tokens'Unrestricted_Access);
            L : constant Tokn_Cursor :=
              Next (Last (Tokens'Unrestricted_Access));
         begin
            Put_Tokens (F, L, L);
         end;
      end if;
   end Put_Tokens;

end Pp.Scanner;

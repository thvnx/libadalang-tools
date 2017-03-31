-- CA11019.A
--
--                             Grant of Unlimited Rights
--
--     Under contracts F33600-87-D-0337, F33600-84-D-0280, MDA903-79-C-0687,
--     F08630-91-C-0015, and DCA100-97-D-0025, the U.S. Government obtained
--     unlimited rights in the software and documentation contained herein.
--     Unlimited rights are defined in DFAR 252.227-7013(a)(19).  By making
--     this public release, the Government intends to confer upon all
--     recipients unlimited rights  equal to those held by the Government.
--     These rights include rights to use, duplicate, release or disclose the
--     released technical data and computer software in whole or in part, in
--     any manner and for any purpose whatsoever, and to have or permit others
--     to do so.
--
--                                    DISCLAIMER
--
--     ALL MATERIALS OR INFORMATION HEREIN RELEASED, MADE AVAILABLE OR
--     DISCLOSED ARE AS IS.  THE GOVERNMENT MAKES NO EXPRESS OR IMPLIED
--     WARRANTY AS TO ANY MATTER WHATSOEVER, INCLUDING THE CONDITIONS OF THE
--     SOFTWARE, DOCUMENTATION OR OTHER INFORMATION RELEASED, MADE AVAILABLE
--     OR DISCLOSED, OR THE OWNERSHIP, MERCHANTABILITY, OR FITNESS FOR A
--     PARTICULAR PURPOSE OF SAID MATERIAL.
--*
--
-- OBJECTIVE:
--      Check that body of the parent package may depend on one of its own
--      private generic children.
--
-- TEST DESCRIPTION:
--      A scenario is created that demonstrates the potential of adding a
--      generic private child during code maintenance without distubing a
--      large subsystem.  After child is added to the subsystem, a maintainer
--      decides to take advantage of the new functionality and rewrites
--      the parent's body.
--
--      Declare a data collection abstraction in a package. Declare a private
--      generic child of this package which provides parameterized code that
--      have been written once and will be used three times to implement the
--      services of the parent package. In the parent body, instantiate the
--      private child.
--
--      In the main program, check that the operations in the parent,
--      and instance of the private child package perform as expected.
--
--
-- CHANGE HISTORY:
--      06 Dec 94   SAIC    ACVC 2.0
--      17 Nov 95   SAIC    Update and repair for ACVC 2.0.1
--
--!

package Ca11019_0 is
   -- parent

   type Data_Record is tagged private;
   type Data_Collection is private;
   ---
   ---
   subtype Data_1 is Integer range 0 .. 100;
   procedure Add_1 (Data : Data_1; To : in out Data_Collection);
   function Statistical_Op_1 (Data : Data_Collection) return Data_1;
   ---
   subtype Data_2 is Integer range -100 .. 1_000;
   procedure Add_2 (Data : Data_2; To : in out Data_Collection);
   function Statistical_Op_2 (Data : Data_Collection) return Data_2;
   ---
   subtype Data_3 is Integer range -10_000 .. 10_000;
   procedure Add_3 (Data : Data_3; To : in out Data_Collection);
   function Statistical_Op_3 (Data : Data_Collection) return Data_3;
   ---

private

   type Data_Ptr is access Data_Record'Class;
   subtype Sequence_Number is Positive range 1 .. 512;

   type Data_Record is tagged record
      Next : Data_Ptr := null;
      Seq  : Sequence_Number;
   end record;
   ---
   type Data_Collection is record
      First : Data_Ptr := null;
      Last  : Data_Ptr := null;
   end record;

end Ca11019_0;
-- C390A021.A
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
--      See C390A022.AM.
--
-- TEST DESCRIPTION:
--      See C390A022.AM.
--
-- TEST FILES:
--      This test consists of the following files:
--
--         F390A00.A
--         C390A020.A
--      => C390A021.A
--         C390A022.AM
--
--
-- CHANGE HISTORY:
--      06 Dec 94   SAIC    ACVC 2.0
--      04 Jun 96   SAIC    ACVC 2.1: Modified prologue.
--
--!

with C390a020;  -- Extended alert abstraction.
package C390a021 is

   -- Declarations used by component Action_Officer;

   type Person_Enum is
     (Nobody, Duty_Officer, Watch_Commander, Commanding_Officer);

   type Medium_Alert_Type is
     new C390a020
       .Low_Alert_Type with private;                                      -- Private extension of
   -- record extension.

   -- Inherits (inherited) procedure Display from Low_Alert_Type.
   -- Inherits function Level_Of from Low_Alert_Type.

   procedure Handle (Ma : in out Medium_Alert_Type);    -- Override parent's
   -- primitive subprog.

   procedure Assign_Officer
     (Ma : in out Medium_Alert_Type;
      To : in     Person_Enum);

   -- The following two functions are needed to verify the values of the
   -- extension's private components.

   function Initial_Values_Okay (Ma : in Medium_Alert_Type) return Boolean;

   function Bad_Final_Values (Ma : in Medium_Alert_Type) return Boolean;

private

   type Medium_Alert_Type is new C390a020.Low_Alert_Type with record
      Action_Officer : Person_Enum := Nobody;
   end record;

end C390a021;
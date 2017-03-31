-----------------------------------------------------------------------------

with F393a00_0;
package body C393a03_0 is

   procedure Bump (A_Counter : in out Counting_Object) is
   begin
      F393a00_0.Tc_Touch ('A');
      A_Counter.Tally := A_Counter.Tally + 1;
   end Bump;

   procedure Zero (A_Counter : in out Counting_Object) is
   begin
      F393a00_0.Tc_Touch ('B');

      -- dispatching call to abstract operation of Counting_Object
      Clear (Counting_Object'Class (A_Counter));

      A_Counter.Tally := 0;

   end Zero;

   function Value (A_Counter : Counting_Object'Class) return Natural is
   begin
      F393a00_0.Tc_Touch ('C');
      return A_Counter.Tally;
   end Value;

end C393a03_0;
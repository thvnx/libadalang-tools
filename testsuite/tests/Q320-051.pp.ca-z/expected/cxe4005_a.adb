-----------------------------------------------------------------------------

with Cxe4005_Common;
with Cxe4005_Part_A1;
with Cxe4005_Part_A2;
with Report;
procedure Cxe4005_A is
begin
   -- this partition is a server that deals with calls
   -- from CXE4005_B.
   Report.Test ("CXE4005_A", "Remote dispatching calls (server)");
   Cxe4005_Part_A1.Can_Quit; -- OK to quit now.

   -- Report.Result is called in the body of CXE4005_Part_A1.
end Cxe4005_A;
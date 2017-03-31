

-----------------------------------------------------------------------------

with Report;
package body CXE4004_Part_B is

  procedure Call_With_4 (T : Integer_Vector) is
    Expected : constant Integer_Vector(1..4) := (4,4,4,4);
  begin
    if T /= Expected then
      Report.Failed ("expected 4 4s but received:" &
                     Integer'Image (T(T'First)) &
                     " length:" &
                     Integer'Image (T'Length));
    end if;
  end;

end CXE4004_Part_B;
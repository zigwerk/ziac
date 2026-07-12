# Ziac Standalone Dashboard Implementation Plan

1. Add a failing ownership/layout contract test for the standalone Ziac
   dashboard and for absence of Ziac routes in the ZigEffect Workbench.
2. Create `packages/ziac/dashboard` with independent Vite, TypeScript, HTML,
   application, bridge, samples, and CSS entry points.
3. Move all Ziac dashboard models, components, and focused tests out of the
   ZigEffect Workbench into the Ziac dashboard.
4. Remove Ziac parsing, bridge methods, samples, and CSS from the ZigEffect
   Workbench.
5. Add Ziac dashboard commands to the root project checks without disturbing
   the existing Ziac marketing-site work.
6. Run focused tests, both dashboard typechecks/tests/builds, and visually
   inspect the standalone Ziac dashboard at port 5178.


#!/bin/bash
cd Github/TankControl-with-substitutes
../ProModSource/scripting/compile.sh l4d_tank_control.sp
cp ../ProModSource/scripting/compiled/l4d_tank_control.smx .
git add *
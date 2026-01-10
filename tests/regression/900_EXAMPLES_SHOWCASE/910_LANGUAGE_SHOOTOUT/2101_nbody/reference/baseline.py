#!/usr/bin/env python3
"""N-body simulation - idiomatic Python"""
import sys
import math

PI = 3.141592653589793
SOLAR_MASS = 4 * PI * PI
DAYS_PER_YEAR = 365.24

bodies = [
    # Sun
    [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, SOLAR_MASS],
    # Jupiter
    [4.84143144246472090e+00, -1.16032004402742839e+00, -1.03622044471123109e-01,
     1.66007664274403694e-03 * DAYS_PER_YEAR, 7.69901118419740425e-03 * DAYS_PER_YEAR,
     -6.90460016972063023e-05 * DAYS_PER_YEAR, 9.54791938424326609e-04 * SOLAR_MASS],
    # Saturn
    [8.34336671824457987e+00, 4.12479856412430479e+00, -4.03523417114321381e-01,
     -2.76742510726862411e-03 * DAYS_PER_YEAR, 4.99852801234917238e-03 * DAYS_PER_YEAR,
     2.30417297573763929e-05 * DAYS_PER_YEAR, 2.85885980666130812e-04 * SOLAR_MASS],
    # Uranus
    [1.28943695621391310e+01, -1.51111514016986312e+01, -2.23307578892655734e-01,
     2.96460137564761618e-03 * DAYS_PER_YEAR, 2.37847173959480950e-03 * DAYS_PER_YEAR,
     -2.96589568540237556e-05 * DAYS_PER_YEAR, 4.36624404335156298e-05 * SOLAR_MASS],
    # Neptune
    [1.53796971148509165e+01, -2.59193146099879641e+01, 1.79258772950371181e-01,
     2.68067772490389322e-03 * DAYS_PER_YEAR, 1.62824170038242295e-03 * DAYS_PER_YEAR,
     -9.51592254519715870e-05 * DAYS_PER_YEAR, 5.15138902046611451e-05 * SOLAR_MASS],
]

def advance(bodies, dt):
    for i in range(len(bodies)):
        for j in range(i + 1, len(bodies)):
            dx = bodies[i][0] - bodies[j][0]
            dy = bodies[i][1] - bodies[j][1]
            dz = bodies[i][2] - bodies[j][2]
            dist = math.sqrt(dx*dx + dy*dy + dz*dz)
            mag = dt / (dist * dist * dist)
            bodies[i][3] -= dx * bodies[j][6] * mag
            bodies[i][4] -= dy * bodies[j][6] * mag
            bodies[i][5] -= dz * bodies[j][6] * mag
            bodies[j][3] += dx * bodies[i][6] * mag
            bodies[j][4] += dy * bodies[i][6] * mag
            bodies[j][5] += dz * bodies[i][6] * mag
    for body in bodies:
        body[0] += dt * body[3]
        body[1] += dt * body[4]
        body[2] += dt * body[5]

def energy(bodies):
    e = 0.0
    for i, body in enumerate(bodies):
        e += 0.5 * body[6] * (body[3]*body[3] + body[4]*body[4] + body[5]*body[5])
        for j in range(i + 1, len(bodies)):
            dx = body[0] - bodies[j][0]
            dy = body[1] - bodies[j][1]
            dz = body[2] - bodies[j][2]
            e -= (body[6] * bodies[j][6]) / math.sqrt(dx*dx + dy*dy + dz*dz)
    return e

def offset_momentum(bodies):
    px = py = pz = 0.0
    for body in bodies:
        px += body[3] * body[6]
        py += body[4] * body[6]
        pz += body[5] * body[6]
    bodies[0][3] = -px / SOLAR_MASS
    bodies[0][4] = -py / SOLAR_MASS
    bodies[0][5] = -pz / SOLAR_MASS

n = int(sys.argv[1]) if len(sys.argv) > 1 else 1000
offset_momentum(bodies)
print(f"{energy(bodies):.9f}")
for _ in range(n):
    advance(bodies, 0.01)
print(f"{energy(bodies):.9f}")

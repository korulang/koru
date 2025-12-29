/* The Computer Language Benchmarks Game
 * https://salsa.debian.org/benchmarksgame-team/benchmarksgame/
 *
 * contributed by Christoph Bauer
 *
 * Modified from: https://benchmarksgame-team.pages.debian.net/benchmarksgame/program/nbody-gcc-1.html
 * License: Revised BSD license
 * Date: 2024-10-25
 */

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#define pi 3.141592653589793
#define solar_mass (4 * pi * pi)
#define days_per_year 365.24

struct planet {
  double x, y, z;
  double vx, vy, vz;
  double mass;
};

void advance(int nbodies, struct planet * bodies, double dt)
{
  int i, j;

  /* Update velocities based on gravitational interactions */
  for (i = 0; i < nbodies; i++) {
    for (j = i + 1; j < nbodies; j++) {
      double dx = bodies[i].x - bodies[j].x;
      double dy = bodies[i].y - bodies[j].y;
      double dz = bodies[i].z - bodies[j].z;
      double distance = sqrt(dx * dx + dy * dy + dz * dz);
      double mag = dt / (distance * distance * distance);
      bodies[i].vx -= dx * bodies[j].mass * mag;
      bodies[i].vy -= dy * bodies[j].mass * mag;
      bodies[i].vz -= dz * bodies[j].mass * mag;
      bodies[j].vx += dx * bodies[i].mass * mag;
      bodies[j].vy += dy * bodies[i].mass * mag;
      bodies[j].vz += dz * bodies[i].mass * mag;
    }
  }

  /* Update positions based on velocities */
  for (i = 0; i < nbodies; i++) {
    bodies[i].x += dt * bodies[i].vx;
    bodies[i].y += dt * bodies[i].vy;
    bodies[i].z += dt * bodies[i].vz;
  }
}

double energy(int nbodies, struct planet * bodies)
{
  double e;
  int i, j;

  e = 0.0;
  for (i = 0; i < nbodies; i++) {
    e += 0.5 * bodies[i].mass * (bodies[i].vx * bodies[i].vx + bodies[i].vy * bodies[i].vy + bodies[i].vz * bodies[i].vz);
    for (j = i + 1; j < nbodies; j++) {
      double dx = bodies[i].x - bodies[j].x;
      double dy = bodies[i].y - bodies[j].y;
      double dz = bodies[i].z - bodies[j].z;
      double distance = sqrt(dx * dx + dy * dy + dz * dz);
      e -= (bodies[i].mass * bodies[j].mass) / distance;
    }
  }
  return e;
}

void offset_momentum(int nbodies, struct planet * bodies)
{
  double px = 0.0, py = 0.0, pz = 0.0;
  int i;
  for (i = 0; i < nbodies; i++) {
    px += bodies[i].vx * bodies[i].mass;
    py += bodies[i].vy * bodies[i].mass;
    pz += bodies[i].vz * bodies[i].mass;
  }
  bodies[0].vx = - px / solar_mass;
  bodies[0].vy = - py / solar_mass;
  bodies[0].vz = - pz / solar_mass;
}

#define NBODIES 5
struct planet bodies[NBODIES] = {
  {                               /* sun */
    0, 0, 0, 0, 0, 0, solar_mass
  },
  {                               /* jupiter */
    4.84143144246472090e+00,
    -1.16032004402742839e+00,
    -1.03622044471123109e-01,
    1.66007664274403694e-03 * days_per_year,
    7.69901118419740425e-03 * days_per_year,
    -6.90460016972063023e-05 * days_per_year,
    9.54791938424326609e-04 * solar_mass
  },
  {                               /* saturn */
    8.34336671824457987e+00,
    4.12479856412430479e+00,
    -4.03523417114321381e-01,
    -2.76742510726862411e-03 * days_per_year,
    4.99852801234917238e-03 * days_per_year,
    2.30417297573763929e-05 * days_per_year,
    2.85885980666130812e-04 * solar_mass
  },
  {                               /* uranus */
    1.28943695621391310e+01,
    -1.51111514016986312e+01,
    -2.23307578892655734e-01,
    2.96460137564761618e-03 * days_per_year,
    2.37847173959480950e-03 * days_per_year,
    -2.96589568540237556e-05 * days_per_year,
    4.36624404335156298e-05 * solar_mass
  },
  {                               /* neptune */
    1.53796971148509165e+01,
    -2.59193146099879641e+01,
    1.79258772950371181e-01,
    2.68067772490389322e-03 * days_per_year,
    1.62824170038242295e-03 * days_per_year,
    -9.51592254519715870e-05 * days_per_year,
    5.15138902046611451e-05 * solar_mass
  }
};

int main(int argc, char ** argv)
{
  int n = atoi(argv[1]);
  int i;

  offset_momentum(NBODIES, bodies);
  printf ("%.9f\n", energy(NBODIES, bodies));
  for (i = 1; i <= n; i++)
    advance(NBODIES, bodies, 0.01);
  printf ("%.9f\n", energy(NBODIES, bodies));
  return 0;
}

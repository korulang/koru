// N-body benchmark - fixed-size scalarized C variant
// Mirrors the fused kernel shape more closely than the generic AoS reference.
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#define PI 3.141592653589793
#define SOLAR_MASS (4 * PI * PI)
#define DAYS_PER_YEAR 365.24
#define DT 0.01

static inline void advance_pair(
    double xi, double yi, double zi,
    double xj, double yj, double zj,
    double mi, double mj,
    double *restrict vxi, double *restrict vyi, double *restrict vzi,
    double *restrict vxj, double *restrict vyj, double *restrict vzj
) {
    const double dx = xi - xj;
    const double dy = yi - yj;
    const double dz = zi - zj;
    const double dsq = dx * dx + dy * dy + dz * dz;
    const double mag = DT / (dsq * sqrt(dsq));

    *vxi -= dx * mj * mag;
    *vyi -= dy * mj * mag;
    *vzi -= dz * mj * mag;
    *vxj += dx * mi * mag;
    *vyj += dy * mi * mag;
    *vzj += dz * mi * mag;
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: nbody_fixed5 <iterations>\n");
        return 1;
    }

    const int n = atoi(argv[1]);
    const double m0 = SOLAR_MASS;
    const double m1 = 9.54791938424326609e-04 * SOLAR_MASS;
    const double m2 = 2.85885980666130812e-04 * SOLAR_MASS;
    const double m3 = 4.36624404335156298e-05 * SOLAR_MASS;
    const double m4 = 5.15138902046611451e-05 * SOLAR_MASS;

    double x0 = 0.0, y0 = 0.0, z0 = 0.0;
    double vx0 = 0.0, vy0 = 0.0, vz0 = 0.0;

    double x1 = 4.84143144246472090e+00;
    double y1 = -1.16032004402742839e+00;
    double z1 = -1.03622044471123109e-01;
    double vx1 = 1.66007664274403694e-03 * DAYS_PER_YEAR;
    double vy1 = 7.69901118419740425e-03 * DAYS_PER_YEAR;
    double vz1 = -6.90460016972063023e-05 * DAYS_PER_YEAR;

    double x2 = 8.34336671824457987e+00;
    double y2 = 4.12479856412430479e+00;
    double z2 = -4.03523417114321381e-01;
    double vx2 = -2.76742510726862411e-03 * DAYS_PER_YEAR;
    double vy2 = 4.99852801234917238e-03 * DAYS_PER_YEAR;
    double vz2 = 2.30417297573763929e-05 * DAYS_PER_YEAR;

    double x3 = 1.28943695621391310e+01;
    double y3 = -1.51111514016986312e+01;
    double z3 = -2.23307578892655734e-01;
    double vx3 = 2.96460137564761618e-03 * DAYS_PER_YEAR;
    double vy3 = 2.37847173959480950e-03 * DAYS_PER_YEAR;
    double vz3 = -2.96589568540237556e-05 * DAYS_PER_YEAR;

    double x4 = 1.53796971148509165e+01;
    double y4 = -2.59193146099879641e+01;
    double z4 = 1.79258772950371181e-01;
    double vx4 = 2.68067772490389322e-03 * DAYS_PER_YEAR;
    double vy4 = 1.62824170038242295e-03 * DAYS_PER_YEAR;
    double vz4 = -9.51592254519715870e-05 * DAYS_PER_YEAR;

    for (int i = 0; i < n; ++i) {
        advance_pair(x0, y0, z0, x1, y1, z1, m0, m1, &vx0, &vy0, &vz0, &vx1, &vy1, &vz1);
        advance_pair(x0, y0, z0, x2, y2, z2, m0, m2, &vx0, &vy0, &vz0, &vx2, &vy2, &vz2);
        advance_pair(x0, y0, z0, x3, y3, z3, m0, m3, &vx0, &vy0, &vz0, &vx3, &vy3, &vz3);
        advance_pair(x0, y0, z0, x4, y4, z4, m0, m4, &vx0, &vy0, &vz0, &vx4, &vy4, &vz4);
        advance_pair(x1, y1, z1, x2, y2, z2, m1, m2, &vx1, &vy1, &vz1, &vx2, &vy2, &vz2);
        advance_pair(x1, y1, z1, x3, y3, z3, m1, m3, &vx1, &vy1, &vz1, &vx3, &vy3, &vz3);
        advance_pair(x1, y1, z1, x4, y4, z4, m1, m4, &vx1, &vy1, &vz1, &vx4, &vy4, &vz4);
        advance_pair(x2, y2, z2, x3, y3, z3, m2, m3, &vx2, &vy2, &vz2, &vx3, &vy3, &vz3);
        advance_pair(x2, y2, z2, x4, y4, z4, m2, m4, &vx2, &vy2, &vz2, &vx4, &vy4, &vz4);
        advance_pair(x3, y3, z3, x4, y4, z4, m3, m4, &vx3, &vy3, &vz3, &vx4, &vy4, &vz4);

        x0 += DT * vx0; y0 += DT * vy0; z0 += DT * vz0;
        x1 += DT * vx1; y1 += DT * vy1; z1 += DT * vz1;
        x2 += DT * vx2; y2 += DT * vy2; z2 += DT * vz2;
        x3 += DT * vx3; y3 += DT * vy3; z3 += DT * vz3;
        x4 += DT * vx4; y4 += DT * vy4; z4 += DT * vz4;
    }

    double e = 0.0;
    e += 0.5 * m0 * (vx0 * vx0 + vy0 * vy0 + vz0 * vz0);
    e += 0.5 * m1 * (vx1 * vx1 + vy1 * vy1 + vz1 * vz1);
    e += 0.5 * m2 * (vx2 * vx2 + vy2 * vy2 + vz2 * vz2);
    e += 0.5 * m3 * (vx3 * vx3 + vy3 * vy3 + vz3 * vz3);
    e += 0.5 * m4 * (vx4 * vx4 + vy4 * vy4 + vz4 * vz4);

    e -= (m0 * m1) / sqrt((x0 - x1) * (x0 - x1) + (y0 - y1) * (y0 - y1) + (z0 - z1) * (z0 - z1));
    e -= (m0 * m2) / sqrt((x0 - x2) * (x0 - x2) + (y0 - y2) * (y0 - y2) + (z0 - z2) * (z0 - z2));
    e -= (m0 * m3) / sqrt((x0 - x3) * (x0 - x3) + (y0 - y3) * (y0 - y3) + (z0 - z3) * (z0 - z3));
    e -= (m0 * m4) / sqrt((x0 - x4) * (x0 - x4) + (y0 - y4) * (y0 - y4) + (z0 - z4) * (z0 - z4));
    e -= (m1 * m2) / sqrt((x1 - x2) * (x1 - x2) + (y1 - y2) * (y1 - y2) + (z1 - z2) * (z1 - z2));
    e -= (m1 * m3) / sqrt((x1 - x3) * (x1 - x3) + (y1 - y3) * (y1 - y3) + (z1 - z3) * (z1 - z3));
    e -= (m1 * m4) / sqrt((x1 - x4) * (x1 - x4) + (y1 - y4) * (y1 - y4) + (z1 - z4) * (z1 - z4));
    e -= (m2 * m3) / sqrt((x2 - x3) * (x2 - x3) + (y2 - y3) * (y2 - y3) + (z2 - z3) * (z2 - z3));
    e -= (m2 * m4) / sqrt((x2 - x4) * (x2 - x4) + (y2 - y4) * (y2 - y4) + (z2 - z4) * (z2 - z4));
    e -= (m3 * m4) / sqrt((x3 - x4) * (x3 - x4) + (y3 - y4) * (y3 - y4) + (z3 - z4) * (z3 - z4));

    fprintf(stderr, "%.9f\n", e);
    return 0;
}

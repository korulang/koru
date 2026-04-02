// N-body benchmark - struct-of-arrays C variant
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#define PI 3.141592653589793
#define SOLAR_MASS (4 * PI * PI)
#define DAYS_PER_YEAR 365.24
#define NBODIES 5
#define DT 0.01

static double x[NBODIES] = {
    0.0,
    4.84143144246472090e+00,
    8.34336671824457987e+00,
    1.28943695621391310e+01,
    1.53796971148509165e+01,
};

static double y[NBODIES] = {
    0.0,
    -1.16032004402742839e+00,
    4.12479856412430479e+00,
    -1.51111514016986312e+01,
    -2.59193146099879641e+01,
};

static double z[NBODIES] = {
    0.0,
    -1.03622044471123109e-01,
    -4.03523417114321381e-01,
    -2.23307578892655734e-01,
    1.79258772950371181e-01,
};

static double vx[NBODIES] = {
    0.0,
    1.66007664274403694e-03 * DAYS_PER_YEAR,
    -2.76742510726862411e-03 * DAYS_PER_YEAR,
    2.96460137564761618e-03 * DAYS_PER_YEAR,
    2.68067772490389322e-03 * DAYS_PER_YEAR,
};

static double vy[NBODIES] = {
    0.0,
    7.69901118419740425e-03 * DAYS_PER_YEAR,
    4.99852801234917238e-03 * DAYS_PER_YEAR,
    2.37847173959480950e-03 * DAYS_PER_YEAR,
    1.62824170038242295e-03 * DAYS_PER_YEAR,
};

static double vz[NBODIES] = {
    0.0,
    -6.90460016972063023e-05 * DAYS_PER_YEAR,
    2.30417297573763929e-05 * DAYS_PER_YEAR,
    -2.96589568540237556e-05 * DAYS_PER_YEAR,
    -9.51592254519715870e-05 * DAYS_PER_YEAR,
};

static const double mass[NBODIES] = {
    SOLAR_MASS,
    9.54791938424326609e-04 * SOLAR_MASS,
    2.85885980666130812e-04 * SOLAR_MASS,
    4.36624404335156298e-05 * SOLAR_MASS,
    5.15138902046611451e-05 * SOLAR_MASS,
};

static inline void advance(void) {
    for (int i = 0; i < NBODIES; ++i) {
        for (int j = i + 1; j < NBODIES; ++j) {
            const double dx = x[i] - x[j];
            const double dy = y[i] - y[j];
            const double dz = z[i] - z[j];
            const double dsq = dx * dx + dy * dy + dz * dz;
            const double mag = DT / (dsq * sqrt(dsq));

            vx[i] -= dx * mass[j] * mag;
            vy[i] -= dy * mass[j] * mag;
            vz[i] -= dz * mass[j] * mag;
            vx[j] += dx * mass[i] * mag;
            vy[j] += dy * mass[i] * mag;
            vz[j] += dz * mass[i] * mag;
        }
    }

    for (int i = 0; i < NBODIES; ++i) {
        x[i] += DT * vx[i];
        y[i] += DT * vy[i];
        z[i] += DT * vz[i];
    }
}

static double energy(void) {
    double e = 0.0;
    for (int i = 0; i < NBODIES; ++i) {
        e += 0.5 * mass[i] * (vx[i] * vx[i] + vy[i] * vy[i] + vz[i] * vz[i]);
        for (int j = i + 1; j < NBODIES; ++j) {
            const double dx = x[i] - x[j];
            const double dy = y[i] - y[j];
            const double dz = z[i] - z[j];
            e -= (mass[i] * mass[j]) / sqrt(dx * dx + dy * dy + dz * dz);
        }
    }
    return e;
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: nbody_soa <iterations>\n");
        return 1;
    }

    const int n = atoi(argv[1]);
    for (int i = 0; i < n; ++i) {
        advance();
    }

    fprintf(stderr, "%.9f\n", energy());
    return 0;
}

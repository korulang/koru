#include <flecs.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

typedef struct {
    int value;
} AgentId;

typedef struct {
    int value;
} Health;

typedef struct {
    int value;
} TargetIndex;

typedef struct {
    int value;
} AttackCooldown;

typedef struct {
    int value;
} StunTimer;

typedef struct {
    int frame;
    uint64_t transitions;
    uint64_t damage_events;
    uint64_t deaths;
    uint64_t checksum;
} ChurnStats;

ECS_COMPONENT_DECLARE(AgentId);
ECS_COMPONENT_DECLARE(Health);
ECS_COMPONENT_DECLARE(TargetIndex);
ECS_COMPONENT_DECLARE(AttackCooldown);
ECS_COMPONENT_DECLARE(StunTimer);
ECS_TAG_DECLARE(Idle);
ECS_TAG_DECLARE(Seeking);
ECS_TAG_DECLARE(Attacking);
ECS_TAG_DECLARE(Stunned);
ECS_TAG_DECLARE(Dead);

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static int arg_int(int argc, char **argv, const char *name, int fallback) {
    for (int i = 1; i + 1 < argc; i++) {
        if (strcmp(argv[i], name) == 0) {
            return atoi(argv[i + 1]);
        }
    }
    return fallback;
}

static void idle_to_seeking(ecs_world_t *world, ecs_query_t *query, ChurnStats *stats) {
    ecs_iter_t it = ecs_query_iter(world, query);
    ecs_defer_begin(world);
    while (ecs_query_next(&it)) {
        AgentId *ids = ecs_field(&it, AgentId, 0);
        for (int32_t i = 0; i < it.count; i++) {
            int id = ids[i].value;
            if ((id + stats->frame) % 11 != 0) {
                continue;
            }
            ecs_entity_t entity = it.entities[i];
            if (!(ecs_has_id(world, entity, Idle) ||
                  ecs_has_id(world, entity, Seeking) ||
                  ecs_has_id(world, entity, Attacking) ||
                  ecs_has_id(world, entity, Stunned))) {
                continue;
            }
            ecs_remove_id(world, entity, Idle);
            ecs_add_id(world, entity, Seeking);
            TargetIndex target = { .value = (id * 17 + stats->frame) % 100000 };
            ecs_set_id(world, entity, ecs_id(TargetIndex), sizeof(TargetIndex), &target);
            stats->transitions++;
        }
    }
    ecs_defer_end(world);
}

static void seeking_to_attacking(ecs_world_t *world, ecs_query_t *query, ChurnStats *stats) {
    ecs_iter_t it = ecs_query_iter(world, query);
    ecs_defer_begin(world);
    while (ecs_query_next(&it)) {
        AgentId *ids = ecs_field(&it, AgentId, 0);
        for (int32_t i = 0; i < it.count; i++) {
            int id = ids[i].value;
            if ((id + stats->frame) % 3 != 0) {
                continue;
            }
            ecs_entity_t entity = it.entities[i];
            ecs_remove_id(world, entity, Seeking);
            ecs_add_id(world, entity, Attacking);
            AttackCooldown cooldown = { .value = 3 + id % 7 };
            ecs_set_id(world, entity, ecs_id(AttackCooldown), sizeof(AttackCooldown), &cooldown);
            stats->transitions++;
        }
    }
    ecs_defer_end(world);
}

static void attack_and_damage(
    ecs_world_t *world,
    ecs_query_t *query,
    ChurnStats *stats,
    const ecs_entity_t *entities,
    int entity_count)
{
    ecs_iter_t it = ecs_query_iter(world, query);
    ecs_defer_begin(world);
    while (ecs_query_next(&it)) {
        AgentId *ids = ecs_field(&it, AgentId, 0);
        TargetIndex *targets = ecs_field(&it, TargetIndex, 1);
        AttackCooldown *cooldowns = ecs_field(&it, AttackCooldown, 2);
        for (int32_t i = 0; i < it.count; i++) {
            cooldowns[i].value -= 1;
            if (cooldowns[i].value > 0) {
                continue;
            }

            int id = ids[i].value;
            int victim_index = (targets[i].value + id * 13) % entity_count;
            ecs_entity_t victim = entities[victim_index];
            if (!ecs_has_id(world, victim, Dead)) {
                Health *health = ecs_get_mut_id(world, victim, ecs_id(Health));
                if (health != NULL) {
                    health->value -= 35;
                    ecs_modified_id(world, victim, ecs_id(Health));
                    stats->damage_events++;
                    stats->checksum += ((uint64_t)health->value * 31ull) + (uint64_t)id;
                }
            }

            ecs_entity_t entity = it.entities[i];
            ecs_remove_id(world, entity, Attacking);
            ecs_remove_id(world, entity, ecs_id(AttackCooldown));
            ecs_remove_id(world, entity, ecs_id(TargetIndex));
            if (id % 23 == 0) {
                ecs_add_id(world, entity, Stunned);
                StunTimer timer = { .value = 2 + id % 5 };
                ecs_set_id(world, entity, ecs_id(StunTimer), sizeof(StunTimer), &timer);
            } else {
                ecs_add_id(world, entity, Idle);
            }
            stats->transitions++;
        }
    }
    ecs_defer_end(world);
}

static void stunned_to_idle(ecs_world_t *world, ecs_query_t *query, ChurnStats *stats) {
    ecs_iter_t it = ecs_query_iter(world, query);
    ecs_defer_begin(world);
    while (ecs_query_next(&it)) {
        StunTimer *timers = ecs_field(&it, StunTimer, 0);
        for (int32_t i = 0; i < it.count; i++) {
            timers[i].value -= 1;
            if (timers[i].value > 0) {
                continue;
            }
            ecs_entity_t entity = it.entities[i];
            ecs_remove_id(world, entity, Stunned);
            ecs_remove_id(world, entity, ecs_id(StunTimer));
            ecs_add_id(world, entity, Idle);
            stats->transitions++;
        }
    }
    ecs_defer_end(world);
}

static void mark_dead(ecs_world_t *world, ecs_query_t *query, ChurnStats *stats) {
    ecs_iter_t it = ecs_query_iter(world, query);
    ecs_defer_begin(world);
    while (ecs_query_next(&it)) {
        Health *health = ecs_field(&it, Health, 0);
        for (int32_t i = 0; i < it.count; i++) {
            if (health[i].value > 0) {
                continue;
            }
            ecs_entity_t entity = it.entities[i];
            ecs_remove_id(world, entity, Idle);
            ecs_remove_id(world, entity, Seeking);
            ecs_remove_id(world, entity, Attacking);
            ecs_remove_id(world, entity, Stunned);
            ecs_remove_id(world, entity, ecs_id(TargetIndex));
            ecs_remove_id(world, entity, ecs_id(AttackCooldown));
            ecs_remove_id(world, entity, ecs_id(StunTimer));
            ecs_add_id(world, entity, Dead);
            stats->transitions++;
            stats->deaths++;
        }
    }
    ecs_defer_end(world);
}

static void health_checksum(ecs_world_t *world, ecs_query_t *query, ChurnStats *stats) {
    ecs_iter_t it = ecs_query_iter(world, query);
    while (ecs_query_next(&it)) {
        AgentId *ids = ecs_field(&it, AgentId, 0);
        Health *health = ecs_field(&it, Health, 1);
        for (int32_t i = 0; i < it.count; i++) {
            stats->checksum += ((uint64_t)ids[i].value * 17ull) + (uint64_t)health[i].value;
        }
    }
}

static int32_t table_count(ecs_world_t *world) {
    ecs_query_t *q = ecs_query(world, { .expr = "AgentId" });
    int32_t count = 0;
    ecs_iter_t it = ecs_query_iter(world, q);
    while (ecs_query_next(&it)) {
        count++;
    }
    ecs_query_fini(q);
    return count;
}

int main(int argc, char **argv) {
    int entities_count = arg_int(argc, argv, "--entities", 100000);
    int frames = arg_int(argc, argv, "--frames", 100);

    ecs_world_t *world = ecs_init();
    ECS_COMPONENT_DEFINE(world, AgentId);
    ECS_COMPONENT_DEFINE(world, Health);
    ECS_COMPONENT_DEFINE(world, TargetIndex);
    ECS_COMPONENT_DEFINE(world, AttackCooldown);
    ECS_COMPONENT_DEFINE(world, StunTimer);
    ECS_TAG_DEFINE(world, Idle);
    ECS_TAG_DEFINE(world, Seeking);
    ECS_TAG_DEFINE(world, Attacking);
    ECS_TAG_DEFINE(world, Stunned);
    ECS_TAG_DEFINE(world, Dead);

    ecs_entity_t *entities = malloc(sizeof(ecs_entity_t) * (size_t)entities_count);
    if (entities == NULL) {
        return 1;
    }

    for (int i = 0; i < entities_count; i++) {
        ecs_entity_t entity = ecs_new(world);
        AgentId id = { .value = i };
        Health health = { .value = 100 + i % 200 };
        ecs_set_id(world, entity, ecs_id(AgentId), sizeof(AgentId), &id);
        ecs_set_id(world, entity, ecs_id(Health), sizeof(Health), &health);
        ecs_add_id(world, entity, Idle);
        entities[i] = entity;
    }

    ecs_query_t *q_idle = ecs_query(world, { .expr = "AgentId, Idle, !Dead" });
    ecs_query_t *q_seeking = ecs_query(world, { .expr = "AgentId, Seeking, !Dead" });
    ecs_query_t *q_attacking = ecs_query(world, { .expr = "AgentId, TargetIndex, AttackCooldown, Attacking, !Dead" });
    ecs_query_t *q_stunned = ecs_query(world, { .expr = "StunTimer, Stunned, !Dead" });
    ecs_query_t *q_mark_dead = ecs_query(world, { .expr = "Health, !Dead" });
    ecs_query_t *q_health = ecs_query(world, { .expr = "AgentId, Health" });

    ChurnStats stats = {0};
    int32_t initial_tables = table_count(world);

    idle_to_seeking(world, q_idle, &stats);
    seeking_to_attacking(world, q_seeking, &stats);
    attack_and_damage(world, q_attacking, &stats, entities, entities_count);
    stunned_to_idle(world, q_stunned, &stats);
    mark_dead(world, q_mark_dead, &stats);
    health_checksum(world, q_health, &stats);
    stats.frame++;
    stats.checksum = 0;

    uint64_t start = now_ns();
    for (int frame = 0; frame < frames; frame++) {
        idle_to_seeking(world, q_idle, &stats);
        seeking_to_attacking(world, q_seeking, &stats);
        attack_and_damage(world, q_attacking, &stats, entities, entities_count);
        stunned_to_idle(world, q_stunned, &stats);
        mark_dead(world, q_mark_dead, &stats);
        health_checksum(world, q_health, &stats);
        stats.frame++;
    }
    uint64_t elapsed = now_ns() - start;

    int32_t final_tables = table_count(world);
    uint64_t sink = stats.checksum +
        stats.transitions * 3ull +
        stats.damage_events * 5ull +
        stats.deaths * 7ull;

    printf(
        "{\"impl\":\"flecs\",\"scenario\":\"archetype_churn_world\","
        "\"entities\":%d,\"frames\":%d,\"observers\":25,"
        "\"elapsed_ns\":%llu,\"sink\":%llu,"
        "\"initial_archetypes\":%d,\"final_archetypes\":%d,"
        "\"transitions\":%llu,\"damage_events\":%llu,\"deaths\":%llu}\n",
        entities_count,
        frames,
        (unsigned long long)elapsed,
        (unsigned long long)sink,
        initial_tables,
        final_tables,
        (unsigned long long)stats.transitions,
        (unsigned long long)stats.damage_events,
        (unsigned long long)stats.deaths);

    ecs_query_fini(q_idle);
    ecs_query_fini(q_seeking);
    ecs_query_fini(q_attacking);
    ecs_query_fini(q_stunned);
    ecs_query_fini(q_mark_dead);
    ecs_query_fini(q_health);
    free(entities);
    ecs_fini(world);
    return 0;
}

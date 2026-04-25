using System;
using System.Diagnostics;
using Unity.Collections;
using Unity.Entities;
using UnityEngine;

public struct AgentId : IComponentData
{
    public int Value;
}

public struct Health : IComponentData
{
    public int Value;
}

public struct Idle : IComponentData {}
public struct Seeking : IComponentData {}
public struct Attacking : IComponentData {}
public struct Stunned : IComponentData {}
public struct Dead : IComponentData {}

public struct TargetIndex : IComponentData
{
    public int Value;
}

public struct AttackCooldown : IComponentData
{
    public int Value;
}

public struct StunTimer : IComponentData
{
    public int Value;
}

public struct ChurnState : IComponentData
{
    public int Frame;
    public ulong Transitions;
    public ulong DamageEvents;
    public ulong Deaths;
    public ulong Checksum;
}

public struct ChurnEntity : IBufferElementData
{
    public Entity Value;
}

public sealed partial class IdleToSeekingSystem : SystemBase
{
    private EntityQuery _query;

    protected override void OnCreate()
    {
        _query = GetEntityQuery(new EntityQueryDesc
        {
            All = new[] { ComponentType.ReadOnly<AgentId>(), ComponentType.ReadOnly<Idle>() },
            None = new[] { ComponentType.ReadOnly<Dead>() }
        });
    }

    protected override void OnUpdate()
    {
        var stateEntity = SystemAPI.GetSingletonEntity<ChurnState>();
        var state = EntityManager.GetComponentData<ChurnState>(stateEntity);
        using var entities = _query.ToEntityArray(Allocator.Temp);
        using var ids = _query.ToComponentDataArray<AgentId>(Allocator.Temp);
        var ecb = new EntityCommandBuffer(Allocator.Temp);

        for (var i = 0; i < entities.Length; i++)
        {
            var id = ids[i].Value;
            if ((id + state.Frame) % 11 != 0) continue;

            ecb.RemoveComponent<Idle>(entities[i]);
            ecb.AddComponent<Seeking>(entities[i]);
            ecb.AddComponent(entities[i], new TargetIndex { Value = (id * 17 + state.Frame) % 100000 });
            state.Transitions++;
        }

        ecb.Playback(EntityManager);
        ecb.Dispose();
        EntityManager.SetComponentData(stateEntity, state);
    }
}

public sealed partial class SeekingToAttackingSystem : SystemBase
{
    private EntityQuery _query;

    protected override void OnCreate()
    {
        _query = GetEntityQuery(new EntityQueryDesc
        {
            All = new[] { ComponentType.ReadOnly<AgentId>(), ComponentType.ReadOnly<Seeking>() },
            None = new[] { ComponentType.ReadOnly<Dead>() }
        });
    }

    protected override void OnUpdate()
    {
        var stateEntity = SystemAPI.GetSingletonEntity<ChurnState>();
        var state = EntityManager.GetComponentData<ChurnState>(stateEntity);
        using var entities = _query.ToEntityArray(Allocator.Temp);
        using var ids = _query.ToComponentDataArray<AgentId>(Allocator.Temp);
        var ecb = new EntityCommandBuffer(Allocator.Temp);

        for (var i = 0; i < entities.Length; i++)
        {
            var id = ids[i].Value;
            if ((id + state.Frame) % 3 != 0) continue;

            ecb.RemoveComponent<Seeking>(entities[i]);
            ecb.AddComponent<Attacking>(entities[i]);
            ecb.AddComponent(entities[i], new AttackCooldown { Value = 3 + id % 7 });
            state.Transitions++;
        }

        ecb.Playback(EntityManager);
        ecb.Dispose();
        EntityManager.SetComponentData(stateEntity, state);
    }
}

public sealed partial class AttackAndDamageSystem : SystemBase
{
    private EntityQuery _query;

    protected override void OnCreate()
    {
        _query = GetEntityQuery(new EntityQueryDesc
        {
            All = new[]
            {
                ComponentType.ReadOnly<AgentId>(),
                ComponentType.ReadOnly<TargetIndex>(),
                ComponentType.ReadWrite<AttackCooldown>(),
                ComponentType.ReadOnly<Attacking>()
            },
            None = new[] { ComponentType.ReadOnly<Dead>() }
        });
    }

    protected override void OnUpdate()
    {
        var stateEntity = SystemAPI.GetSingletonEntity<ChurnState>();
        var state = EntityManager.GetComponentData<ChurnState>(stateEntity);
        var allEntities = EntityManager.GetBuffer<ChurnEntity>(stateEntity);
        var victimCount = Math.Max(1, allEntities.Length);
        using var attackers = _query.ToEntityArray(Allocator.Temp);
        using var ids = _query.ToComponentDataArray<AgentId>(Allocator.Temp);
        using var targets = _query.ToComponentDataArray<TargetIndex>(Allocator.Temp);
        using var cooldowns = _query.ToComponentDataArray<AttackCooldown>(Allocator.Temp);
        var ecb = new EntityCommandBuffer(Allocator.Temp);

        for (var i = 0; i < attackers.Length; i++)
        {
            var cooldown = cooldowns[i];
            cooldown.Value -= 1;
            EntityManager.SetComponentData(attackers[i], cooldown);
            if (cooldown.Value > 0) continue;

            var id = ids[i].Value;
            var victimIndex = (targets[i].Value + id * 13) % victimCount;
            var victim = allEntities[victimIndex].Value;

            if (EntityManager.Exists(victim) &&
                !EntityManager.HasComponent<Dead>(victim) &&
                EntityManager.HasComponent<Health>(victim))
            {
                var health = EntityManager.GetComponentData<Health>(victim);
                health.Value -= 35;
                EntityManager.SetComponentData(victim, health);
                state.DamageEvents++;
                state.Checksum = state.Checksum + ((ulong)health.Value * 31UL) + (ulong)id;
            }

            ecb.RemoveComponent<Attacking>(attackers[i]);
            ecb.RemoveComponent<AttackCooldown>(attackers[i]);
            ecb.RemoveComponent<TargetIndex>(attackers[i]);
            if (id % 23 == 0)
            {
                ecb.AddComponent<Stunned>(attackers[i]);
                ecb.AddComponent(attackers[i], new StunTimer { Value = 2 + id % 5 });
            }
            else
            {
                ecb.AddComponent<Idle>(attackers[i]);
            }
            state.Transitions++;
        }

        ecb.Playback(EntityManager);
        ecb.Dispose();
        EntityManager.SetComponentData(stateEntity, state);
    }
}

public sealed partial class StunnedToIdleSystem : SystemBase
{
    private EntityQuery _query;

    protected override void OnCreate()
    {
        _query = GetEntityQuery(new EntityQueryDesc
        {
            All = new[] { ComponentType.ReadWrite<StunTimer>(), ComponentType.ReadOnly<Stunned>() },
            None = new[] { ComponentType.ReadOnly<Dead>() }
        });
    }

    protected override void OnUpdate()
    {
        var stateEntity = SystemAPI.GetSingletonEntity<ChurnState>();
        var state = EntityManager.GetComponentData<ChurnState>(stateEntity);
        using var entities = _query.ToEntityArray(Allocator.Temp);
        using var timers = _query.ToComponentDataArray<StunTimer>(Allocator.Temp);
        var ecb = new EntityCommandBuffer(Allocator.Temp);

        for (var i = 0; i < entities.Length; i++)
        {
            var timer = timers[i];
            timer.Value -= 1;
            EntityManager.SetComponentData(entities[i], timer);
            if (timer.Value > 0) continue;

            ecb.RemoveComponent<Stunned>(entities[i]);
            ecb.RemoveComponent<StunTimer>(entities[i]);
            ecb.AddComponent<Idle>(entities[i]);
            state.Transitions++;
        }

        ecb.Playback(EntityManager);
        ecb.Dispose();
        EntityManager.SetComponentData(stateEntity, state);
    }
}

public sealed partial class MarkDeadSystem : SystemBase
{
    private EntityQuery _query;

    protected override void OnCreate()
    {
        _query = GetEntityQuery(new EntityQueryDesc
        {
            All = new[] { ComponentType.ReadOnly<Health>() },
            None = new[] { ComponentType.ReadOnly<Dead>() },
            Any = new[]
            {
                ComponentType.ReadOnly<Idle>(),
                ComponentType.ReadOnly<Seeking>(),
                ComponentType.ReadOnly<Attacking>(),
                ComponentType.ReadOnly<Stunned>()
            }
        });
    }

    protected override void OnUpdate()
    {
        var stateEntity = SystemAPI.GetSingletonEntity<ChurnState>();
        var state = EntityManager.GetComponentData<ChurnState>(stateEntity);
        using var entities = _query.ToEntityArray(Allocator.Temp);
        using var health = _query.ToComponentDataArray<Health>(Allocator.Temp);
        var ecb = new EntityCommandBuffer(Allocator.Temp);

        for (var i = 0; i < entities.Length; i++)
        {
            if (health[i].Value > 0) continue;

            if (EntityManager.HasComponent<Idle>(entities[i])) ecb.RemoveComponent<Idle>(entities[i]);
            if (EntityManager.HasComponent<Seeking>(entities[i])) ecb.RemoveComponent<Seeking>(entities[i]);
            if (EntityManager.HasComponent<Attacking>(entities[i])) ecb.RemoveComponent<Attacking>(entities[i]);
            if (EntityManager.HasComponent<Stunned>(entities[i])) ecb.RemoveComponent<Stunned>(entities[i]);
            if (EntityManager.HasComponent<TargetIndex>(entities[i])) ecb.RemoveComponent<TargetIndex>(entities[i]);
            if (EntityManager.HasComponent<AttackCooldown>(entities[i])) ecb.RemoveComponent<AttackCooldown>(entities[i]);
            if (EntityManager.HasComponent<StunTimer>(entities[i])) ecb.RemoveComponent<StunTimer>(entities[i]);
            ecb.AddComponent<Dead>(entities[i]);
            state.Transitions++;
            state.Deaths++;
        }

        ecb.Playback(EntityManager);
        ecb.Dispose();
        EntityManager.SetComponentData(stateEntity, state);
    }
}

public sealed partial class HealthChecksumSystem : SystemBase
{
    private EntityQuery _query;

    protected override void OnCreate()
    {
        _query = GetEntityQuery(ComponentType.ReadOnly<AgentId>(), ComponentType.ReadOnly<Health>());
        _query.SetChangedVersionFilter(ComponentType.ReadOnly<Health>());
    }

    protected override void OnUpdate()
    {
        var stateEntity = SystemAPI.GetSingletonEntity<ChurnState>();
        var state = EntityManager.GetComponentData<ChurnState>(stateEntity);
        using var ids = _query.ToComponentDataArray<AgentId>(Allocator.Temp);
        using var health = _query.ToComponentDataArray<Health>(Allocator.Temp);

        for (var i = 0; i < ids.Length; i++)
        {
            state.Checksum = state.Checksum + ((ulong)ids[i].Value * 17UL) + (ulong)health[i].Value;
        }

        EntityManager.SetComponentData(stateEntity, state);
    }
}

public sealed partial class AdvanceFrameSystem : SystemBase
{
    protected override void OnUpdate()
    {
        var stateEntity = SystemAPI.GetSingletonEntity<ChurnState>();
        var state = EntityManager.GetComponentData<ChurnState>(stateEntity);
        state.Frame += 1;
        EntityManager.SetComponentData(stateEntity, state);
    }
}

public static class DotsArchetypeChurnBenchmark
{
    public static void Run()
    {
        var entities = GetIntArg("--entities", 100000);
        var frames = GetIntArg("--frames", 100);
        var world = new World("DotsArchetypeChurnBenchmark");
        var entityManager = world.EntityManager;
        var stateEntity = entityManager.CreateEntity(typeof(ChurnState));
        var allEntities = entityManager.AddBuffer<ChurnEntity>(stateEntity);
        allEntities.ResizeUninitialized(entities);

        var initialArchetype = entityManager.CreateArchetype(
            typeof(AgentId),
            typeof(Idle),
            typeof(Health));

        using (var created = entityManager.CreateEntity(initialArchetype, entities, Allocator.Temp))
        {
            for (var i = 0; i < created.Length; i++)
            {
                var entity = created[i];
                entityManager.SetComponentData(entity, new AgentId { Value = i });
                entityManager.SetComponentData(entity, new Health { Value = 100 + i % 200 });
                allEntities[i] = new ChurnEntity { Value = entity };
            }
        }

        var systems = new ComponentSystemBase[]
        {
            world.CreateSystemManaged<IdleToSeekingSystem>(),
            world.CreateSystemManaged<SeekingToAttackingSystem>(),
            world.CreateSystemManaged<AttackAndDamageSystem>(),
            world.CreateSystemManaged<StunnedToIdleSystem>(),
            world.CreateSystemManaged<MarkDeadSystem>(),
            world.CreateSystemManaged<HealthChecksumSystem>(),
            world.CreateSystemManaged<AdvanceFrameSystem>()
        };

        var initialArchetypes = entityManager.GetAllArchetypes(Allocator.Temp).Length;
        foreach (var system in systems) system.Update();
        var state = entityManager.GetComponentData<ChurnState>(stateEntity);
        state.Checksum = 0;
        entityManager.SetComponentData(stateEntity, state);

        var stopwatch = Stopwatch.StartNew();
        for (var frame = 0; frame < frames; frame++)
        {
            foreach (var system in systems) system.Update();
        }
        stopwatch.Stop();

        state = entityManager.GetComponentData<ChurnState>(stateEntity);
        var finalArchetypes = entityManager.GetAllArchetypes(Allocator.Temp).Length;
        var elapsedNs = (long)(stopwatch.ElapsedTicks * (1000000000.0 / Stopwatch.Frequency));
        var sink = state.Checksum +
                   state.Transitions * 3UL +
                   state.DamageEvents * 5UL +
                   state.Deaths * 7UL;

        Debug.Log(
            "{\"impl\":\"unity_dots\",\"scenario\":\"archetype_churn_world\"" +
            $",\"entities\":{entities}" +
            $",\"frames\":{frames}" +
            ",\"observers\":25" +
            $",\"elapsed_ns\":{elapsedNs}" +
            $",\"sink\":{sink}" +
            $",\"initial_archetypes\":{initialArchetypes}" +
            $",\"final_archetypes\":{finalArchetypes}" +
            $",\"transitions\":{state.Transitions}" +
            $",\"damage_events\":{state.DamageEvents}" +
            $",\"deaths\":{state.Deaths}" +
            "}");

        world.Dispose();
    }

    private static int GetIntArg(string name, int fallback)
    {
        var args = Environment.GetCommandLineArgs();
        for (var i = 0; i < args.Length - 1; i++)
        {
            if (args[i] == name && int.TryParse(args[i + 1], out var value))
            {
                return value;
            }
        }
        return fallback;
    }
}

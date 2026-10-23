using System;
using System.Collections.Generic;

namespace Core;

public sealed class CombatLog : IReader
{
    private const int PLAYER_DEATH_EVENT = 16777215;

    /// <summary>Target GUID cell (see PlayerReader.TargetGuid).</summary>
    public const int TargetGuidCell = 57;

    private readonly AddonBits bits;

    private bool wasInCombat;

    // Clients without a combat log (WoW Forever): the addon can miss a death
    // when the target is cleared right away, so also credit a kill when the
    // target we fought while it was alive shows up dead.
    private int fightingTargetGuid;
    private readonly HashSet<int> credited = [];

    public event Action? KillCredit;
    public event Action? PlayerDeath;
    public event Action? TargetEvade;

    public HashSet<int> DamageDone { get; } = [];
    public HashSet<int> DamageTaken { get; } = [];
    public HashSet<int> EvadeMobs { get; } = [];
    public HashSet<int> EnemySummons { get; } = [];

    public HashSet<int> ToPull { get; } = [];

    public int DamageTakenCount() => DamageTaken.Count;
    public int DamageDoneCount() => DamageDone.Count;

    public int ToPullCount() => ToPull.Count;

    public RecordInt DamageDoneGuid { get; }
    public RecordInt DamageTakenGuid { get; }
    public RecordInt DeadGuid { get; }

    public RecordInt TargetMissType { get; }
    public RecordInt TargetDodge { get; }

    public RecordInt LastDamageDoneTime { get; }
    public RecordInt EnemySummonGuid { get; }

    public CombatLog(AddonBits bits)
    {
        this.bits = bits;

        DamageDoneGuid = new RecordInt(64);
        DamageTakenGuid = new RecordInt(65);
        DeadGuid = new RecordInt(66);

        LastDamageDoneTime = new(109);
        EnemySummonGuid = new(110);

        TargetMissType = new(67);
        TargetDodge = new(67);
    }

    public void Reset()
    {
        wasInCombat = false;
        fightingTargetGuid = 0;
        credited.Clear();

        DamageDone.Clear();
        DamageTaken.Clear();
        EnemySummons.Clear();

        DamageDoneGuid.Reset();
        DamageTakenGuid.Reset();
        DeadGuid.Reset();

        LastDamageDoneTime.Reset();
        EnemySummonGuid.Reset();

        TargetMissType.Reset();
        TargetDodge.Reset();
    }

    public void Update(IAddonDataProvider reader)
    {
        bool combat = bits.Combat();

        LastDamageDoneTime.Update(reader);

        if (combat && DamageTakenGuid.Updated(reader) && DamageTakenGuid.Value > 0)
        {
            DamageTaken.Add(DamageTakenGuid.Value);
        }

        if (combat && DamageDoneGuid.Updated(reader) && DamageDoneGuid.Value > 0)
        {
            DamageDone.Add(DamageDoneGuid.Value);
        }

        if (combat && EnemySummonGuid.Updated(reader) && EnemySummonGuid.Value > 0)
        {
            EnemySummons.Add(EnemySummonGuid.Value);
        }

        if (TargetMissType.Updated(reader))
        {
            switch ((MissType)TargetMissType.Value)
            {
                case MissType.DODGE:
                    TargetDodge.UpdateTime();
                    break;
                case MissType.EVADE:
                    if (DamageDoneGuid.Value > 0)
                    {
                        EvadeMobs.Add(DamageDoneGuid.Value);
                        TargetEvade?.Invoke();
                    }
                    break;
            }
        }

        if (DeadGuid.Updated(reader) && DeadGuid.Value > 0)
        {
            int deadGuid = DeadGuid.Value;
            DamageDone.Remove(deadGuid);
            DamageTaken.Remove(deadGuid);
            ToPull.Remove(deadGuid);

            if (deadGuid == PLAYER_DEATH_EVENT)
            {
                PlayerDeath?.Invoke();
            }
            else if (credited.Add(deadGuid))
            {
                KillCredit?.Invoke();
            }
        }

        int targetGuid = reader.GetInt(TargetGuidCell);
        if (targetGuid > 0)
        {
            if (combat && bits.Target_NotDead())
            {
                fightingTargetGuid = targetGuid;
            }
            else if (bits.Target_Dead() && targetGuid == fightingTargetGuid)
            {
                fightingTargetGuid = 0;
                if (credited.Add(targetGuid))
                {
                    DamageDone.Remove(targetGuid);
                    DamageTaken.Remove(targetGuid);
                    ToPull.Remove(targetGuid);
                    KillCredit?.Invoke();
                }
            }
        }

        if (wasInCombat && !combat)
        {
            // left combat
            DamageTaken.Clear();
            DamageDone.Clear();
            EnemySummons.Clear();
            ToPull.Clear();
        }

        // keep the duplicate guard small; GUIDs are only needed for a short while
        if (credited.Count > 64)
            credited.Clear();

        wasInCombat = combat;
    }
}
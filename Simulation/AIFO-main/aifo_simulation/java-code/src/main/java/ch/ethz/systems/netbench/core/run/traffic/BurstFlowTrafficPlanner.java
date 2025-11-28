package ch.ethz.systems.netbench.core.run.traffic;

import ch.ethz.systems.netbench.core.Simulator;
import ch.ethz.systems.netbench.core.network.TransportLayer;
import ch.ethz.systems.netbench.ext.poissontraffic.flowsize.FlowSizeDistribution;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Random;
import java.util.Set;

/**
 * Traffic planner generating bursty flows.
 * Two modes:
 *  - periodic: bursts repeat every 'burstIntervalNs', each lasts 'burstDurationNs'
 *  - random  : windows of length 'windowDurationNs' with burst probability
 *
 * Supports:
 *  - fixed-size flows (backward compatible)
 *  - distribution-based flow sizes (to match Poisson's flow size distribution)
 *
 * Destination pairs: currently supports "all_to_all".
 */
public class BurstFlowTrafficPlanner extends TrafficPlanner {

    // Common
    private final int totalFlows;
    private final Random rand;
    private final String burstMode; // "periodic" or "random"
    private final String pairGenerator; // e.g., "all_to_all"

    // Flow size mode A: fixed size (legacy)
    private final boolean useFixedSize;
    private final long flowSizeByte;

    // Flow size mode B: distribution-based
    private final boolean useFsd;
    private final FlowSizeDistribution flowSizeDistribution;

    // Periodic burst params
    private final long burstIntervalNs;
    private final long burstDurationNs;

    // Random burst params
    private final int windowFlows;
    private final long windowDurationNs;

    /* ========= Constructor A: fixed-size (legacy) ========= */
    public BurstFlowTrafficPlanner(
            Map<Integer, TransportLayer> idToTransportLayerMap,
            int totalFlows,
            long flowSizeByte,
            String burstMode,
            long burstIntervalNs,
            long burstDurationNs,
            int windowFlows,
            long windowDurationNs
    ) {
        super(idToTransportLayerMap);
        this.totalFlows = totalFlows;
        this.useFixedSize = true;
        this.flowSizeByte = flowSizeByte;
        this.useFsd = false;
        this.flowSizeDistribution = null;

        this.burstMode = burstMode;
        this.burstIntervalNs = burstIntervalNs;
        this.burstDurationNs = burstDurationNs;
        this.windowFlows = windowFlows;
        this.windowDurationNs = windowDurationNs;

        // default to all_to_all to match common Poisson setups
        this.pairGenerator = "all_to_all";

        long seed = Simulator.getConfiguration().getLongPropertyOrFail("seed");
        this.rand = new Random(seed);
    }

    /* ========= Constructor B: distribution-based (for comparability with Poisson) ========= */
    public BurstFlowTrafficPlanner(
            Map<Integer, TransportLayer> idToTransportLayerMap,
            int totalFlows,
            FlowSizeDistribution flowSizeDistribution,
            String burstMode,
            long burstIntervalNs,
            long burstDurationNs,
            int windowFlows,
            long windowDurationNs,
            String pairGenerator // e.g., "all_to_all"
    ) {
        super(idToTransportLayerMap);
        this.totalFlows = totalFlows;
        this.useFixedSize = false;
        this.flowSizeByte = 0L;
        this.useFsd = true;
        this.flowSizeDistribution = flowSizeDistribution;

        this.burstMode = burstMode;
        this.burstIntervalNs = burstIntervalNs;
        this.burstDurationNs = burstDurationNs;
        this.windowFlows = windowFlows;
        this.windowDurationNs = windowDurationNs;

        this.pairGenerator = (pairGenerator == null) ? "all_to_all" : pairGenerator;

        long seed = Simulator.getConfiguration().getLongPropertyOrFail("seed");
        this.rand = new Random(seed);
    }

    @Override
    public void createPlan(long durationNs) {

        // Gather server ids
        Set<Integer> serverSet = graphDetails.getServerNodeIds();
        List<Integer> serverList = new ArrayList<>(serverSet);
        Integer[] servers = serverList.toArray(new Integer[0]);

        if (burstMode.equalsIgnoreCase("periodic")) {
            createPeriodicBurst(servers, durationNs);
        } else if (burstMode.equalsIgnoreCase("random")) {
            createRandomBurst(servers, durationNs);
        } else {
            throw new IllegalArgumentException("Unknown burst mode: " + burstMode);
        }
    }

    private void createPeriodicBurst(Integer[] servers, long durationNs) {
        if (burstIntervalNs <= 0) {
            throw new IllegalArgumentException("burstIntervalNs must be > 0 for periodic mode.");
        }
        // How many full bursts fit in the simulation time
        int bursts = (int) Math.max(1, durationNs / burstIntervalNs);

        // Divide total flows across bursts evenly, spread remainder
        int base = totalFlows / bursts;
        int rem  = totalFlows % bursts;

        int flowsCreated = 0;
        for (int b = 0; b < bursts; b++) {
            int flowsThisBurst = base + (b < rem ? 1 : 0);
            long burstStartTime = b * burstIntervalNs;

            for (int i = 0; i < flowsThisBurst; i++) {
                long timeOffset = (long) (rand.nextDouble() * Math.max(1, burstDurationNs));
                long startTime = burstStartTime + timeOffset;
                if (startTime >= durationNs) {
                    // If this flow would start after simulation end, clamp slightly before end
                    startTime = Math.max(0, durationNs - 1);
                }

                int srcId, dstId;
                Pair pair = pickPair(servers);
                srcId = pair.src;
                dstId = pair.dst;

                long sizeByte = pickFlowSizeByte();
                registerFlow(startTime, srcId, dstId, sizeByte);
                flowsCreated++;
            }
        }

        // Safety: if integer division dropped some (shouldn't happen with above logic), fill up
        while (flowsCreated < totalFlows) {
            long startTime = Math.min(durationNs - 1, Math.abs(rand.nextLong()) % Math.max(1, durationNs));
            Pair pair = pickPair(servers);
            registerFlow(startTime, pair.src, pair.dst, pickFlowSizeByte());
            flowsCreated++;
        }
    }

    private void createRandomBurst(Integer[] servers, long durationNs) {
        long currentTime = 0;
        int flowsCreated = 0;

        while (flowsCreated < totalFlows && currentTime < durationNs) {

            boolean isBurst = rand.nextDouble() < 0.1; // 10% burst windows
            int flowsThisWindow = isBurst ? windowFlows : Math.max(1, windowFlows / 10);

            for (int j = 0; j < flowsThisWindow && flowsCreated < totalFlows; j++, flowsCreated++) {
                long timeOffset = (long) (rand.nextDouble() * Math.max(1, windowDurationNs));
                long startTime = currentTime + timeOffset;
                if (startTime >= durationNs) {
                    startTime = Math.max(0, durationNs - 1);
                }

                Pair pair = pickPair(servers);
                registerFlow(startTime, pair.src, pair.dst, pickFlowSizeByte());
            }

            currentTime += windowDurationNs;
        }
    }

    private long pickFlowSizeByte() {
        if (useFsd) {
            return flowSizeDistribution.generateFlowSizeByte();
        } else {
            return flowSizeByte;
        }
    }

    // Destination pair picker: currently supports "all_to_all"
    private Pair pickPair(Integer[] servers) {
        switch (pairGenerator) {
            case "all_to_all":
                int srcId, dstId;
                do {
                    srcId = servers[rand.nextInt(servers.length)];
                    dstId = servers[rand.nextInt(servers.length)];
                } while (srcId == dstId);
                return new Pair(srcId, dstId);

            default:
                throw new IllegalArgumentException("Unsupported pair generator for burst_flow: " + pairGenerator);
        }
    }

    private static class Pair {
        final int src;
        final int dst;
        Pair(int s, int d) { this.src = s; this.dst = d; }
    }
}

package ch.ethz.systems.netbench.xpt.aifo.ports.DFQ;

import ch.ethz.systems.netbench.core.log.SimulationLogger;
import ch.ethz.systems.netbench.core.network.Link;
import ch.ethz.systems.netbench.core.network.NetworkDevice;
import ch.ethz.systems.netbench.core.network.OutputPort;
import ch.ethz.systems.netbench.core.run.infrastructure.OutputPortGenerator;

public class DFQOutputPortGenerator extends OutputPortGenerator {

    private final long numQueues;
    private final long perQueueCapacity;
    private final long bytesPerRound;
    private final int windowSize;

    public DFQOutputPortGenerator(long numQueues, long perQueueCapacity, long bytesPerRound, int windowSize) {
        this.numQueues = numQueues;
        this.perQueueCapacity = perQueueCapacity;
        this.bytesPerRound = bytesPerRound;
        this.windowSize = windowSize;
        SimulationLogger.logInfo("Port", "DFQ(numQueues=" + numQueues + ", perQueueCapacity=" + perQueueCapacity +
                ", bytesPerRound=" + bytesPerRound + ", windowSize=" + windowSize + ")");
    }

    @Override
    public OutputPort generate(NetworkDevice ownNetworkDevice, NetworkDevice towardsNetworkDevice, Link link) {
        return new DFQOutputPort(ownNetworkDevice, towardsNetworkDevice, link,
                numQueues, perQueueCapacity, bytesPerRound, windowSize);
    }
}
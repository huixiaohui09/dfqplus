package ch.ethz.systems.netbench.xpt.aifo.ports.EFQ;

import ch.ethz.systems.netbench.core.log.SimulationLogger;
import ch.ethz.systems.netbench.core.network.Link;
import ch.ethz.systems.netbench.core.network.NetworkDevice;
import ch.ethz.systems.netbench.core.network.OutputPort;
import ch.ethz.systems.netbench.core.run.infrastructure.OutputPortGenerator;

public class EFQOutputPortGenerator extends OutputPortGenerator {

    private final long numQueues;
    private final long perQueueCapacity;
    private final long bytesPerRound;

    public EFQOutputPortGenerator(long numQueues, long perQueueCapacity, long bytesPerRound) {
        this.numQueues = numQueues;
        this.perQueueCapacity = perQueueCapacity;
        this.bytesPerRound = bytesPerRound;
        SimulationLogger.logInfo("Port", "EFQ(numQueues=" + numQueues +  ", perQueueCapacity=" + perQueueCapacity + ", bytesPerRound=" + bytesPerRound + ")");
    }

    @Override
    public OutputPort generate(NetworkDevice ownNetworkDevice, NetworkDevice towardsNetworkDevice, Link link) {
        return new EFQOutputPort(ownNetworkDevice, towardsNetworkDevice, link, numQueues, perQueueCapacity, bytesPerRound);
    }

}
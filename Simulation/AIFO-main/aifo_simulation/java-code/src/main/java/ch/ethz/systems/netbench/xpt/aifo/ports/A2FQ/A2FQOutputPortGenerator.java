package ch.ethz.systems.netbench.xpt.aifo.ports.A2FQ;

import ch.ethz.systems.netbench.core.log.SimulationLogger;
import ch.ethz.systems.netbench.core.network.Link;
import ch.ethz.systems.netbench.core.network.NetworkDevice;
import ch.ethz.systems.netbench.core.network.OutputPort;
import ch.ethz.systems.netbench.core.run.infrastructure.OutputPortGenerator;

public class A2FQOutputPortGenerator extends OutputPortGenerator {

    private final long numQueues;
    private final long perQueueCapacity;
    private final long bytesPerRound;

    public A2FQOutputPortGenerator(long numQueues, long perQueueCapacity, long bytesPerRound) {
        this.numQueues = numQueues;
        this.perQueueCapacity = perQueueCapacity;
        this.bytesPerRound = bytesPerRound;
        SimulationLogger.logInfo("Port", "A2FQ(numQueues=" + numQueues +  ", perQueueCapacity=" + perQueueCapacity + ", bytesPerRound=" + bytesPerRound + ")");
    }

    @Override
    public OutputPort generate(NetworkDevice ownNetworkDevice, NetworkDevice towardsNetworkDevice, Link link) {
        return new A2FQOutputPort(ownNetworkDevice, towardsNetworkDevice, link, numQueues, perQueueCapacity, bytesPerRound);
    }

}
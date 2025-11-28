package ch.ethz.systems.netbench.core.run.traffic;

import ch.ethz.systems.netbench.core.Simulator;
import ch.ethz.systems.netbench.core.config.GraphDetails;
import ch.ethz.systems.netbench.core.network.TransportLayer;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Random;
import java.util.Set;

public class FixedFlowTrafficPlanner extends TrafficPlanner {

    private final int totalFlows;       // 总流数量
    private final long flowSizeByte;    // 每个流大小（字节）
    private final long interArrivalNs;  // 流间隔时间（纳秒）
    private final Random rand;

    public FixedFlowTrafficPlanner(
        Map<Integer, TransportLayer> idToTransportLayerMap,
        int totalFlows,
        long flowSizeByte,
        long interArrivalNs
    ) {
        super(idToTransportLayerMap);
        this.totalFlows = totalFlows;
        this.flowSizeByte = flowSizeByte;
        this.interArrivalNs = interArrivalNs;
        
        // 修正：使用正确的随机种子获取方式
        long seed = Simulator.getConfiguration().getLongPropertyOrFail("seed");
        this.rand = new Random(seed);
    }

    @Override
    public void createPlan(long durationNs) {
        // 修正：正确处理服务器节点ID集合
        Set<Integer> serverSet = graphDetails.getServerNodeIds();
        List<Integer> serverList = new ArrayList<>(serverSet);
        Integer[] servers = serverList.toArray(new Integer[0]);
        
        for (int i = 0; i < totalFlows; i++) {
            // 随机选择源和目的服务器（避免自环）
            int srcId, dstId;
            do {
                srcId = servers[rand.nextInt(servers.length)];
                dstId = servers[rand.nextInt(servers.length)];
            } while (srcId == dstId);

            // 注册TCP流（使用父类的registerFlow方法）
            registerFlow(i * interArrivalNs, srcId, dstId, flowSizeByte);
        }
    }
}
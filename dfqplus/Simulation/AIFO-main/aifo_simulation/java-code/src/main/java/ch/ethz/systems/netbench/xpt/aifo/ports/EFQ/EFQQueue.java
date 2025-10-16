package ch.ethz.systems.netbench.xpt.aifo.ports.EFQ;

import ch.ethz.systems.netbench.core.network.Packet;
import ch.ethz.systems.netbench.xpt.tcpbase.FullExtTcpPacket;

import java.util.*;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.locks.ReentrantLock;

public class EFQQueue implements Queue {

    private final int Q; // Queue size
    private final int M; // Number of priority FIFO queues
    private int N; // Number of active flows
    private final double T; // Sampling interval in ns
    private int R; // Current round number
    private int Quota; // Fair share in each queue

    private final int[] Used; // Total occupancy in each queue
    private final Map<Long, Integer> Last; // Last queue number for each active flow
    private final Map<Long, int[]> Util; // Utilization in each queue for each active flow
    private final Map<Long, Boolean> Active; // Active state of each flow

    private final ArrayList<ArrayBlockingQueue<FullExtTcpPacket>> queues;
    private final ReentrantLock reentrantLock;
    private long lastUpdateTime;
    private final int ownId;

    public EFQQueue(long numQueues, long perQueueCapacity, long bytesPerRound, int ownId) {
        this.Q = (int) perQueueCapacity;
        this.M = (int) numQueues;
        this.T = 0.000000001;
        this.N = 1;
        this.R = 0;
        this.Quota = Q / N;

        this.Used = new int[M];
        this.Last = new HashMap<>();
        this.Util = new HashMap<>();
        this.Active = new HashMap<>();

        this.queues = new ArrayList<>(M);
        for (int i = 0; i < M; i++) {
            queues.add(new ArrayBlockingQueue<>(Q));
        }

        this.reentrantLock = new ReentrantLock();
        this.lastUpdateTime = System.nanoTime();
        this.ownId = ownId;
    }

    private void updateActiveFlows() {
        long currentTime = System.nanoTime();
        if (currentTime - lastUpdateTime >= T) {
            N = 0;
            for (Map.Entry<Long, Boolean> entry : Active.entrySet()) {
                if (entry.getValue()) {
                    N++;
                    Active.put(entry.getKey(), false);
                }
            }
            Quota = Q / Math.max(N, 1); // Avoid division by zero
            lastUpdateTime = currentTime;
        }
    }

    @Override
    public boolean offer(Object o) {
        reentrantLock.lock();
        try {
            updateActiveFlows();

            FullExtTcpPacket pkt = (FullExtTcpPacket) o;
            long fid = pkt.getFlowId();

            int q_in = -1;
            if (!Active.getOrDefault(fid, false)) {
                for (int i = 0; i < M && q_in == -1; i++) {
                    int qIndex = (R + i) % M;
                    if (Quota > Util.getOrDefault(fid, new int[M])[qIndex] && Used[qIndex] < Q) {
                        q_in = qIndex;
                    }
                }
            } else {
                int lastQueue = Last.getOrDefault(fid, 0);
                if (Quota > Util.getOrDefault(fid, new int[M])[lastQueue] && Used[lastQueue] < Q) {
                    q_in = lastQueue;
                } else if (lastQueue < R + M - 1) {
                    q_in = (lastQueue + 1) % M;
                }
            }

            if (q_in == -1) {
                return false; // Drop packet
            }

            queues.get(q_in).offer(pkt);
            Util.computeIfAbsent(fid, k -> new int[M])[q_in]++;
            Used[q_in]++;
            Last.put(fid, q_in);
            Active.put(fid, true);

            return true;
        } finally {
            reentrantLock.unlock();
        }
    }

    @Override
    public Packet poll() {
        reentrantLock.lock();
        try {
            while (true) {
                int q_out = R;
                ArrayBlockingQueue<FullExtTcpPacket> currentQueue = queues.get(q_out);

                while (!currentQueue.isEmpty()) {
                    FullExtTcpPacket pkt = currentQueue.poll();
                    if (pkt != null) {
                        long fid = pkt.getFlowId();
                        Util.get(fid)[q_out]--;
                        Used[q_out]--;
                        return pkt;
                    }
                }

                R = (R + 1) % M;
            }
        } finally {
            reentrantLock.unlock();
        }
    }

    @Override
    public int size() {
        reentrantLock.lock();
        try {
            return Arrays.stream(Used).sum();
        } finally {
            reentrantLock.unlock();
        }
    }

    @Override
    public boolean isEmpty() {
        return size() == 0;
    }

    @Override
    public boolean contains(Object o) {
        return false;
    }

    @Override
    public Iterator iterator() {
        return null;
    }

    @Override
    public Object[] toArray() {
        return new Object[0];
    }

    @Override
    public Object[] toArray(Object[] objects) {
        return new Object[0];
    }

    @Override
    public boolean add(Object o) {
        return false;
    }

    @Override
    public boolean remove(Object o) {
        return false;
    }

    @Override
    public boolean addAll(Collection collection) {
        return false;
    }

    @Override
    public void clear() { }

    @Override
    public boolean retainAll(Collection collection) {
        return false;
    }

    @Override
    public boolean removeAll(Collection collection) {
        return false;
    }

    @Override
    public boolean containsAll(Collection collection) {
        return false;
    }

    @Override
    public Object remove() {
        return null;
    }

    @Override
    public Object element() {
        return null;
    }

    @Override
    public Object peek() {
        return null;
    }
}
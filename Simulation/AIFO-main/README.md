# Simulation

#### 1. Software dependencies

* **Java 8:** Version 8 of Java; both Oracle JDK and OpenJDK are supported and produce under that same seed deterministic results. Additionally the project uses the **Apache Maven** software project management and comprehension tool (version 3+).

* **Python 3:** Recent version of Python 3 for analysis; be sure you can globally run `python3 <script.py>`. Packge required: pandas, matplotlib. You can install them via pip.



#### 2. Software structure

There are three sub-packages in [*netbench*](https://github.com/nsg-ethz/sp-pifo): (a) core, containing core functionality, (b) ext (extension), which contains functionality implemented and quite thoroughly tested, and (c) xpt (experimental), which contains functionality not yet as thoroughly tested but reasonably vetted and assumed to be correct for the usecase it was written for.

The framework is written based on five core components:

1. **Network device**: abstraction of a node, can be a server (has a transport layer) or merely function as switch (no transport layer);
2. **Transport layer**: maintains the sockets for each of the flows that are started at the network device and for which it is the destination;
3. **Intermediary**: placed between the network device and transport layer, is able to modify each packet before arriving at the transport layer and after leaving the transport layer;
4. **Link**: quantifies the capabilities of the physical link, which the output port respects;
5. **Output port**: models output ports and their queueing behavior.

Look into `ch.ethz.systems.netbench.ext.demo` for an impression how to extend the framework.  If you've written an extension, it is necessary to add it in its respective selector in `ch.ethz.systems.netbench.run`. If you've added new properties, be sure to add them in the `ch.ethz.systems.netbench.config.BaseAllowedProperties` class.

More information about the framework can be found in the thesis located at [https://www.research-collection.ethz.ch/handle/20.500.11850/156350](https://www.research-collection.ethz.ch/handle/20.500.11850/156350) (section 4.2: NetBench: Discrete Packet Simulator).

#### 3. Building

Build the executable `NetBench.jar` by using the following maven command: 

```
cd dfqplus/Simulation/AIFO-main/aifo_simulation/java-code
mvn clean compile assembly:single
```

#### 4. Running
1.

   ```
java -jar -ea NetBench.jar 6
   ```

After the run, the log files are saved in the `dfqplus/Simulation/AIFO-main/aifo_simulation/java-code/temp/aifo/aifo_evaluation/fairness/window_size` folder. The corresponding results are presented in Figure 6.

2.

   ```
java -jar -ea NetBench.jar 7
   ```

After the run, the log files are saved in the `dfqplus/Simulation/AIFO-main/aifo_simulation/java-code/temp/aifo/aifo_evaluation/fairness/web_search_workload` folder. The corresponding results are shown in Figures 7, 9, 10, 11, and 12, and Table 2.

3.

   ```
java -jar -ea NetBench.jar 8
   ```

After the run, the log files are saved in the `dfqplus/Simulation/AIFO-main/aifo_simulation/java-code/temp/aifo/aifo_evaluation/fairness/data_mining_workload` folder. The corresponding results are presented in Figure 8.

4.

   ```
java -jar -ea NetBench.jar 100
   ```

After the run, the log files are saved in the `dfqplus/Simulation/AIFO-main/aifo_simulation/java-code/temp/aifo/aifo_evaluation/fairness/different_topology` folder. The corresponding results are presented in Tables 3 and 4.

5.

   ```
java -jar -ea NetBench.jar 18
   ```

After the run, the log files are saved in the `dfqplus/Simulation/AIFO-main/aifo_simulation/java-code/temp/aifo/aifo_evaluation/fairness/burst` folder. The corresponding results are presented in Figure 18.

6.
For the ablation experiments, modify the `DFQQueue.java` file in `dfqplus/Simulation/AIFO-main/aifo_simulation/java-code/src/main/java/ch/ethz/systems/netbench/xpt/aifo/ports/DFQ`, which contains the three versions of our DFQ implementation. Then, edit `MainFigure7.java` in `aifo_simulation/java-code/src/main/java/ch/ethz/systems/netbench/core/run` by commenting out all other algorithms and keeping only the DFQ execution code. Finally, run:

```bash
java -jar -ea NetBench.jar 7
```

and analyze the results.

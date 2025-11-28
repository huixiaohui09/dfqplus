package ch.ethz.systems.netbench.core.run;

public class MainSimulation {

    public static void main(String args[]) {
        if (args.length == 0) {
            System.out.println("Please specify which experiments to run!");
            return;
        }

        if (args.length != 1) {
            System.out.println("Please specify only one experiment to run!");
            return;
        }

        int figureIndex = Integer.parseInt(args[0]);
        String[] dummy = new String[0];

        switch (figureIndex) {

            case 6:
                MainFigure6.main(dummy);
                break;

            case 7:
                MainFigure7.main(dummy);
                break;

            case 8:
                MainFigure8.main(dummy);
                break;

            case 18:
                MainFigure18.main(dummy);
                break;

            case 100:   // 自定义编号：运行 Table3
                Table3.main(dummy);
                break;

            case 0:
                // Run all experiments you currently have
                MainFigure6.main(dummy);
                MainFigure7.main(dummy);
                MainFigure8.main(dummy);
                MainFigure18.main(dummy);
                Table3.main(dummy);
                break;

            default:
                System.out.println(
                    "Unknown experiment index! Valid options: " +
                    "6, 7, 8, 18, 100 (Table3), or 0 (run all)."
                );
        }
    }
}

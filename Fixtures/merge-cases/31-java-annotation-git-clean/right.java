public class Shape {
    private final double side;

    public Shape(double side) {
        this.side = side;
    }

    public double area() {
        return Math.pow(side, 2);
    }

    public String toString() {
        return "Shape(" + side + ")";
    }
}

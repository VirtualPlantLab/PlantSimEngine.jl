import { AlertTriangle, RotateCcw } from "lucide-react";
import { Component, type ErrorInfo, type ReactNode } from "react";

export class ErrorBoundary extends Component<{ children: ReactNode }, { error: Error | null }> {
  state: { error: Error | null } = { error: null };

  static getDerivedStateFromError(error: Error) {
    return { error };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error("PlantSimEngine model graph frontend failed", error, info);
  }

  render() {
    if (!this.state.error) return this.props.children;
    return <main className="frontend-error" data-testid="frontend-error">
      <AlertTriangle size={28} />
      <h1>The graph view could not be rendered</h1>
      <p>{this.state.error.message}</p>
      <button onClick={() => window.location.reload()}><RotateCcw size={15} /> Reload graph</button>
    </main>;
  }
}

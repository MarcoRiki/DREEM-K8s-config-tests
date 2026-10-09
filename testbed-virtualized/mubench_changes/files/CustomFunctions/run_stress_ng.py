import subprocess
import random

def run_stress_ng(params):
    max_cpu = params['n_cpu']
    fixed = params['fixed']
    duration = params.get('duration', None)
    cpu_ops = params.get('cpu_ops', None)
    
    
    if fixed:
        n_cpu = max_cpu
        if duration is not None:
            duration = params['duration']
    else:
        n_cpu = random.randint(1, max_cpu)
        if duration is not None:
            duration = random.randint(1, duration)
            
            
    if duration is not None:
        cmd = [
            "stress-ng",
            "--cpu", str(n_cpu),
            "--timeout", f"{duration}s",
        ]
    elif cpu_ops is not None:
        cmd = [
        "stress-ng",
        "--cpu", str(n_cpu),
        "--cpu-ops", str(cpu_ops)
        ]

    try:
        print("Avvio stress-ng...")
        result = subprocess.run(cmd, check=True)
        print("stress-ng terminato correttamente")

    except subprocess.CalledProcessError as e:
        print(f"Errore durante l'esecuzione: {e}")

    except FileNotFoundError:
        print("stress-ng non trovato. Verifica che sia installato e nel PATH.")
    
    return 'Completed execution of stress-ng'        


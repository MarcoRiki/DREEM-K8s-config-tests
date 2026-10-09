import json
import os
import yaml
from pprint import pprint
from copy import deepcopy
import random

K8s_YAML_BUILDER_PATH = os.path.dirname(os.path.abspath(__file__))

SIDECAR_TEMPLATE = "- name: %s-sidecar\n          image: %s"
NODE_AFFINITY_TEMPLATE = {'affinity': {'nodeAffinity': {'requiredDuringSchedulingIgnoredDuringExecution': {'nodeSelectorTerms': [{'matchExpressions': [{'key': 'kubernetes.io/hostname','operator': 'In','values': ['']}]}]}}}}
POD_ANTIAFFINITI_TEMPLATE = {'affinity':{'podAntiAffinity':{'requiredDuringSchedulingIgnoredDuringExecution':[{'labelSelector':{'matchExpressions':[{'key':'app','operator':'In','values':['']}]},'topologyKey':'kubernetes.io/hostname'}]}}}
TOPOLOGY_SPREAD_TEMPLATE = {'topologySpreadConstraints': [{'maxSkew': 1, 'topologyKey': 'kubernetes.io/hostname', 'whenUnsatisfiable': 'ScheduleAnyway', 'labelSelector': {'matchLabels': {'app': ''}}}]}
PREFERRED_NODE_AFFINITY_TEMPLATE = {
    'affinity': {
        'nodeAffinity': {
            'preferredDuringSchedulingIgnoredDuringExecution': [
                {
                    'weight': 100,
                    'preference': {
                        'matchExpressions': [
                            {
                                'key': 'size',
                                'operator': 'In',
                                'values': [] # Popolato dinamicamente con ['small'] o ['big']
                            }
                        ]
                    }
                }
            ]
        }
    }
}

# Override work_model params with those in k8s_parameters
def customization_work_model(workmodel, k8s_parameters):
    for service in workmodel:
        workmodel[service].update({"url": f"{service}.{k8s_parameters['namespace']}.svc.{k8s_parameters['cluster_domain']}.local"})
        workmodel[service].update({"path": k8s_parameters['path']})
        workmodel[service].update({"image": k8s_parameters['image']})
        workmodel[service].update({"namespace": k8s_parameters['namespace']})
                    
        if "scheduler-name" in workmodel[service].keys():
            # override scheduler-name value of workmodel.json
            workmodel[service].update({"scheduler-name": k8s_parameters['scheduler-name']})
        if "replicas" in k8s_parameters.keys():
            # override replica value of workmodel.json
            workmodel[service].update({"replicas": k8s_parameters['replicas']})
        if "cpu-requests" in k8s_parameters.keys():
            # override cpu-requests value of workmodel.json
            workmodel[service].update({"cpu-requests": k8s_parameters['cpu-requests']})
        if "cpu-limits" in k8s_parameters.keys():
            # override cpu-limits value of workmodel.json
            workmodel[service].update({"cpu-limits": k8s_parameters['cpu-limits']})
        if "memory-requests" in k8s_parameters.keys():
            # override memory-requests value of workmodel.json
            workmodel[service].update({"memory-requests": k8s_parameters['memory-requests']})
        if "memory-limits" in k8s_parameters.keys():
            # override memory-limits value of workmodel.json
            workmodel[service].update({"memory-limits": k8s_parameters['memory-limits']})
    print("Work Model Updated!")


def create_deployment_service_yaml_files(workmodel, k8s_parameters, nfs, output_path):
    namespace = k8s_parameters['namespace']
    counter = 0
    for service in workmodel:
        counter += 1

        # 1. Carichiamo il file di template direttamente come DIZIONARIO Python
        with open(f"{K8s_YAML_BUILDER_PATH}/Templates/DeploymentTemplate.yaml", "r") as file:
            # NOTA: Poiché il template ha dei tag orfani come {{NODE_AFFINITY}} o {{RESOURCES}}, 
            # leggiamolo come stringa, rimuoviamo temporaneamente i tag inutilizzati per non far crashare il parser,
            # oppure facciamo i replace testuali SEMPLICI prima di darlo a YAML.
            template_content = file.read()
            
        # Sostituzioni testuali base semplici (stringa -> stringa)
        template_content = template_content.replace("{{SERVICE_NAME}}", service)
        template_content = template_content.replace("{{IMAGE}}", workmodel[service]["image"])
        template_content = template_content.replace("{{NAMESPACE}}", namespace)
        
        if "scheduler-name" in workmodel[service].keys():
            template_content = template_content.replace("{{SCHEDULER_NAME}}", str(workmodel[service]["scheduler-name"]))
        else:
            template_content = template_content.replace("{{SCHEDULER_NAME}}", "default-scheduler")
            
        if "replicas" in workmodel[service].keys():
            template_content = template_content.replace("{{REPLICAS}}", str(workmodel[service]["replicas"]))
        else:
            template_content = template_content.replace("{{REPLICAS}}", "1")

        # Rimuoviamo i tag complessi dal testo prima del caricamento per non corrompere la sintassi YAML
        # Li gestiremo nativamente come oggetti Python strutturati
        template_content = template_content.replace("{{NODE_AFFINITY}}", "")
        template_content = template_content.replace("{{POD_ANTIAFFINITY}}", "")
        template_content = template_content.replace("{{TOPOLOGY_SPREAD}}", "")
        template_content = template_content.replace("{{SIDECAR}}", "")
        template_content = template_content.replace("{{RESOURCES}}", "{}") # Fallback sicuro
        template_content = template_content.replace("{{PN}}", f"'{workmodel[service].get('workers', 1)}'")
        template_content = template_content.replace("{{TN}}", f"'{workmodel[service].get('threads', 4)}'")

        # 2. Convertiamo la struttura pulita in un dizionario Python
        deployment_dict = yaml.safe_load(template_content)

        # Scorciatoia per arrivare allo spec del Pod all'interno dell'oggetto Deployment
        pod_spec = deployment_dict['spec']['template']['spec']

        # 3. Gestione Nativa Python delle Risorse (Resources)
        if len(set(workmodel[service].keys()).intersection({"cpu-limits", "memory-limits", "cpu-requests", "memory-requests"})):
            resources = {}
            if "cpu-requests" in workmodel[service] or "memory-requests" in workmodel[service]:
                resources["requests"] = {}
                if "cpu-requests" in workmodel[service]: resources["requests"]["cpu"] = workmodel[service]["cpu-requests"]
                if "memory-requests" in workmodel[service]: resources["requests"]["memory"] = workmodel[service]["memory-requests"]
            if "cpu-limits" in workmodel[service] or "memory-limits" in workmodel[service]:
                resources["limits"] = {}
                if "cpu-limits" in workmodel[service]: resources["limits"]["cpu"] = workmodel[service]["cpu-limits"]
                if "memory-limits" in workmodel[service]: resources["limits"]["memory"] = workmodel[service]["memory-limits"]
            pod_spec['containers'][0]['resources'] = resources

        # 4. Iniezione Nativa della Preferred Node Affinity
        if "preferred_node_size" in workmodel[service].keys():
                size_value = workmodel[service]["preferred_node_size"]
                pod_spec['affinity'] = {
                    'nodeAffinity': {
                        'preferredDuringSchedulingIgnoredDuringExecution': [
                            {
                                'weight': random.randint(75, 100),  # Peso casuale tra 1 e 100
                                'preference': {
                                    'matchExpressions': [{'key': 'size', 'operator': 'In', 'values': [size_value]}]
                                }
                            }
                        ]
                    }
                }
        elif "preferred_group" in workmodel[service].keys():
            group_prefs = workmodel[service]["preferred_group"]   # {"A": 100, "B": 40}
            if 'affinity' not in pod_spec:
                pod_spec['affinity'] = {}
            pod_spec['affinity']['nodeAffinity'] = {
                'preferredDuringSchedulingIgnoredDuringExecution': [
                    {'weight': w, 'preference': {'matchExpressions':
                        [{'key': 'group', 'operator': 'In', 'values': [g]}]}}
                    for g, w in group_prefs.items()
                ]
            }

            
        elif "required_node_labels" in workmodel[service].keys():
            # hard placement on nodes carrying every given label, e.g. {"size": ["big"]}
            if 'affinity' not in pod_spec:
                pod_spec['affinity'] = {}
            pod_spec['affinity']['nodeAffinity'] = {
                'requiredDuringSchedulingIgnoredDuringExecution': {
                    'nodeSelectorTerms': [{'matchExpressions': [
                        {'key': key, 'operator': 'In', 'values': values if isinstance(values, list) else [values]}
                        for key, values in workmodel[service]["required_node_labels"].items()
                    ]}]
                }
            }

        elif "node_affinity" in workmodel[service].keys():
            pod_spec['affinity'] = {
                'nodeAffinity': {
                    'requiredDuringSchedulingIgnoredDuringExecution': {
                        'nodeSelectorTerms': [{'matchExpressions': [{'key': 'kubernetes.io/hostname', 'operator': 'In', 'values': workmodel[service]["node_affinity"]}]}]
                    }
                }
            }

        # 4b. Preferred inter-pod affinity, e.g. {"aa": 100}: prefer the node already
        #     running a pod of each named service (same node, hostname topology)
        if "preferred_pod_affinity" in workmodel[service].keys():
            if 'affinity' not in pod_spec:
                pod_spec['affinity'] = {}
            pod_spec['affinity']['podAffinity'] = {
                'preferredDuringSchedulingIgnoredDuringExecution': [
                    {'weight': int(weight), 'podAffinityTerm': {
                        'labelSelector': {'matchLabels': {'app': target}},
                        'topologyKey': 'kubernetes.io/hostname'}}
                    for target, weight in workmodel[service]["preferred_pod_affinity"].items()
                ]
            }

        # 5. Iniezione Nativa della Topology Spread / AntiAffinity
        if "pod_topology_spread" in workmodel[service].keys() and workmodel[service]['pod_topology_spread'] == True:
            max_skew = workmodel[service].get('max_skew', 1)
            pod_spec['topologySpreadConstraints'] = [{
                'maxSkew': max_skew,
                'topologyKey': 'kubernetes.io/hostname',
                'whenUnsatisfiable': 'ScheduleAnyway',
                'labelSelector': {'matchLabels': {'app': service}}
            }]
        elif "pod_antiaffinity" in workmodel[service].keys() and workmodel[service]['pod_antiaffinity'] == True:
            # Se esiste già un blocco affinity (creato sopra dalla node affinity), facciamo l'update
            if 'affinity' not in pod_spec:
                pod_spec['affinity'] = {}
            pod_spec['affinity']['podAntiAffinity'] = {
                'requiredDuringSchedulingIgnoredDuringExecution': [{
                    'labelSelector': {'matchExpressions': [{'key': 'app', 'operator': 'In', 'values': [service]}]},
                    'topologyKey': 'kubernetes.io/hostname'
                }]
            }

        # 6. Gestione Sidecar
        if "sidecar" in workmodel[service].keys():
            pod_spec['containers'].append({
                'name': f"{service}-sidecar",
                'image': workmodel[service]["sidecar"]
            })

        # Calcolo del rank string per il nome del file
        rank_string = '00000'
        if "cpu-requests" in workmodel[service].keys():
            if 'm' in workmodel[service]["cpu-requests"]:
                rank_string = str(int(workmodel[service]["cpu-requests"].replace('m', ''))).zfill(5)
            else:
                rank_string = str(int(float(workmodel[service]["cpu-requests"]) * 1000)).zfill(5)

        if not os.path.exists(f"{output_path}/yamls"):
            os.makedirs(f"{output_path}/yamls")

        # 7. SCRITTURA FINALE: Ci pensa PyYAML a fare il dump perfetto senza errori di spazi!
        filepath = f"{output_path}/yamls/{k8s_parameters['prefix_yaml_file']}-{str(rank_string).zfill(3)}-Deployment-{service}.yaml"
        with open(filepath, "w") as file:
            yaml.dump(deployment_dict, file, default_flow_style=False, sort_keys=False)

         # Create Service yamls
        with open(f"{K8s_YAML_BUILDER_PATH}/Templates/ServiceTemplate.yaml", "r") as file:
            f = file.read()
            f = f.replace("{{SERVICE_NAME}}", service)
            f = f.replace("{{NAMESPACE}}", namespace)
        with open(f"{output_path}/yamls/{k8s_parameters['prefix_yaml_file']}-{str(rank_string).zfill(3)}-Service-{service}.yaml", "w") as file:
            file.write(f)

    if k8s_parameters["nginx-gw"] == True:
        # create nginx gw deployment yaml files
        with open(f"{K8s_YAML_BUILDER_PATH}/Templates/ConfigMapNginxGwTemplate.yaml", "r") as file:
            f = file.read()
            f = f.replace("{{NAMESPACE}}", namespace)
            f = f.replace("{{PATH}}", k8s_parameters["path"])
            f = f.replace("{{RESOLVER}}", k8s_parameters["dns-resolver"])

        with open(f"{output_path}/yamls/{k8s_parameters['prefix_yaml_file']}-ConfigMapNginxGw.yaml", "w") as file:
            file.write(f)

        with open(f"{K8s_YAML_BUILDER_PATH}/Templates/DeploymentNginxGwTemplate.yaml", "r") as file:
            f = file.read()
            f = f.replace("{{NAMESPACE}}", namespace)
            f = f.replace("{{SVCTYPE}}", k8s_parameters["nginx-svc-type"])
            if "scheduler-name" in workmodel[service].keys():
                f = f.replace("{{SCHEDULER_NAME}}", str(workmodel[service]["scheduler-name"]))
            else:
                f = f.replace("{{SCHEDULER_NAME}}", "default-scheduler")
            
        with open(f"{output_path}/yamls/{k8s_parameters['prefix_yaml_file']}-DeploymentNginxGw.yaml", "w") as file:
            file.write(f)
    print("Deployments and Services Created!")
def create_workmodel_configmap_yaml_file(workmodel, k8s_parameters, nfs, output_path):
    namespace = k8s_parameters['namespace']
    with open(f"{K8s_YAML_BUILDER_PATH}/Templates/ConfigMapWorkmodelTemplate.yaml", "r") as file:
        f = file.read()
        f = f.replace("{{NAMESPACE}}", namespace)
        j = json.dumps(workmodel,indent=2)
        j = '    '.join(j.splitlines(True))
        f = f.replace("{{WORKMODEL}}", j)
    with open(f"{output_path}/yamls/{k8s_parameters['prefix_yaml_file']}-ConfigMapWorkmodel.yaml", "w") as file:
        file.write(f)
    print("Workmodel Configmap Created!")

def create_internalservice_configmap_yaml_file(k8s_parameters, nfs, output_path, internal_service_functions_path):
    namespace = k8s_parameters['namespace']
    data_dict = dict()
    if internal_service_functions_path != "" or internal_service_functions_path is None:
        src_files = os.listdir(internal_service_functions_path)
        for file_name in src_files:
            full_file_name = os.path.join(internal_service_functions_path, file_name)
            if os.path.isfile(full_file_name):
                with open(full_file_name, 'r') as f:
                    file_content=f.read()
                    data_dict[file_name]=file_content      
    with open(f"{K8s_YAML_BUILDER_PATH}/Templates/ConfigMapInternalServicesTemplate.yaml", "r") as file:
        f = file.read()
        f = f.replace("{{NAMESPACE}}", namespace)
        j = json.dumps(data_dict,indent=2)
        j = '  '.join(j.splitlines(True))
        f = f.replace("{{DATA}}", j)
    with open(f"{output_path}/yamls/{k8s_parameters['prefix_yaml_file']}-ConfigMapInternalServices.yaml", "w") as file:
        file.write(f)
    print("Internal-Services Configmap Created!")

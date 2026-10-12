README.md
# devops-monitoring-stack

Mon projet perso pour m'entraîner au DevOps après ma formation d'administrateur systèmes DevOps à La Capsule.

Le but : **déployer et superviser un serveur Nginx** sur AWS, en automatisant un maximum de choses avec **Terraform**, **Ansible**, **Docker Compose**, **Prometheus** et **Grafana**.



## Comment j'ai travaillé : d'une EC2 vers une autre

Pour ce projet, j'ai utilisé **deux instances EC2** :

- **Une EC2 de contrôle** : c'est la machine sur laquelle je travaille (connectée avec VS Code). Elle contient mon code, Terraform et Ansible.
- **Une EC2 cible** : c'est la machine que Terraform crée, et sur laquelle Ansible installe et lance la stack de supervision.

```
 EC2 de contrôle                          EC2 cible
 ┌───────────────────────┐   SSH    ┌───────────────────────────────┐
 │ VS Code, Git          │ ───────► │ Docker Compose                │
 │ Terraform  ─ crée ───►│          │  ├─ nginx             :80     │
 │ Ansible    ─ configure│          │  ├─ nginx-exporter    :9113   │ (interne)
 └───────────────────────┘          │  ├─ prometheus        :9090   │
                                    │  └─ grafana           :3000   │
                                    └───────────────────────────────┘
```

Le déroulé :
1. Depuis l'EC2 de contrôle, Terraform crée l'EC2 cible, son groupe de sécurité et sa paire de clés SSH.
2. Toujours depuis l'EC2 de contrôle, Ansible se connecte en SSH à l'EC2 cible, copie la configuration et lance `docker compose`.
3. Je vérifie ensuite que tout répond, depuis l'EC2 de contrôle ou via un tunnel SSH pour voir les interfaces web.

Je n'ai jamais eu besoin de me connecter à la main sur l'EC2 cible pour installer quoi que ce soit (sauf pour déboguer). Ça m'a permis de comprendre l'intérêt d'automatiser : si je détruis la cible, je peux la recréer en relançant les commandes.

## Ce que fait la stack

| Service | Rôle |
|---|---|
| `nginx` | Un serveur web simple à surveiller (port 80) |
| `nginx-exporter` | Lit les statistiques de Nginx et les met au format Prometheus |
| `prometheus` | Récupère les métriques toutes les 15 secondes et les stocke |
| `grafana` | Affiche les métriques sous forme de graphiques |

Nginx expose ses stats sur un port interne, l'exporter les lit, Prometheus les collecte, et Grafana les affiche.

## Outils utilisés

- **Terraform** : créer l'infrastructure AWS avec du code (région `eu-north-1`)
- **Ansible** : configurer l'EC2 cible et déployer les conteneurs
- **Docker / Docker Compose** : lancer les services
- **Prometheus, Grafana, nginx-prometheus-exporter** : la partie supervision

## Structure du dépôt

```
.
├── terraform/      # l'infrastructure AWS
├── ansible/        # le playbook et les fichiers de configuration
│   ├── playbook.yml
│   ├── ansible.cfg
│   └── files/      # docker-compose.yml, config nginx, prometheus, grafana
├── docs/           # captures d'écran
└── .gitignore
```

## Reproduire le projet

### Ce qu'il faut avant

- Un compte AWS et la CLI configurée (`aws configure`)
- Une EC2 « de contrôle » (Ubuntu) avec Terraform, Ansible et Git installés
- La collection Ansible Docker : `ansible-galaxy collection install community.docker`
- Une clé SSH **sans passphrase** (voir plus bas pourquoi) :
  ```bash
  ssh-keygen -t ed25519 -f ~/.ssh/monitest -C monitest
  ```

### 1. Créer l'EC2 cible avec Terraform

```bash
git clone https://github.com/pkanga91/devops-monitoring-stack.git
cd devops-monitoring-stack/terraform

# l'IP de ma machine de contrôle, la seule autorisée en SSH
echo "my_ip_cidr = \"$(curl -4 -s ifconfig.me)/32\"" > terraform.tfvars

terraform init
terraform plan -out=monitest.tfplan
terraform apply monitest.tfplan
terraform output -raw server_public_ip
```

### 2. Dire à Ansible où se connecter

Je crée un fichier `inventory.ini` (pas versionné, car il contient une IP) :

```ini
[monitoring]
IP_DE_LA_CIBLE ansible_user=ubuntu ansible_ssh_private_key_file=/home/ubuntu/.ssh/monitest ansible_ssh_common_args='-o IdentitiesOnly=yes'
```

```bash
cd ../ansible
ansible monitoring -m ping      # doit répondre "pong"
```

### 3. Déployer

```bash
ansible-playbook playbook.yml
```

Si je le relance une deuxième fois, il affiche `changed=0` : Ansible ne refait pas ce qui est déjà fait.

## Vérifier

```bash
IP=IP_DE_LA_CIBLE
curl -I http://$IP                  # HTTP/1.1 200 OK
curl -s http://$IP:9090/-/healthy   # Prometheus Server is Healthy.
curl -s http://$IP:9090/api/v1/targets | python3 -m json.tool | grep '"health"'   # "up"
```

Requêtes que j'ai utilisées dans Grafana :

- `nginx_up` : Nginx répond-il ?
- `nginx_connections_active` : connexions en cours
- `rate(nginx_http_requests_total[1m])` : requêtes par seconde
- `rate(nginx_connections_accepted[1m])` et `rate(nginx_connections_handled[1m])` : connexions acceptées et traitées

Pour faire bouger les courbes, je génère du trafic :

```bash
for i in $(seq 1 100); do curl -s -o /dev/null http://$IP; done
```

![Cibles Prometheus](docs/prometheus-targets.png)
![Tableau de bord Grafana](docs/grafana-dashboard.png)

## Voir Prometheus et Grafana depuis mon navigateur

Les ports 9090 et 3000 ne sont ouverts qu'à une IP précise, pas à tout Internet. Comme je travaille depuis l'EC2 de contrôle avec VS Code, j'utilise un tunnel SSH, puis l'onglet « Ports » de VS Code :

```bash
ssh -i ~/.ssh/monitest -fN -L 3000:localhost:3000 -L 9090:localhost:9090 ubuntu@IP_DE_LA_CIBLE
```

Ensuite : `http://localhost:3000` (Grafana, `admin` / `admin`, à changer à la première connexion) et `http://localhost:9090` (Prometheus).

## Sécurité (ce que j'ai essayé de faire)

- SSH, Grafana et Prometheus limités à une seule IP (`/32`), jamais `0.0.0.0/0`.
- L'exporter n'est pas exposé : il est joignable uniquement dans le réseau Docker.
- Aucun secret dans le dépôt : `.tfvars`, états Terraform, clés SSH et `inventory.ini` sont dans le `.gitignore`.
- Versions des images Docker fixées dans le `docker-compose.yml`.

Je sais que ce n'est pas du niveau production, voir « Ce que je voudrais améliorer ».

## Ce qui m'a bloqué (et ce que j'ai appris)

- **Image Ubuntu introuvable** : mon filtre `aws_ami` utilisait le mauvais chemin. Pour Ubuntu 24.04, c'est `hvm-ssd-gp3`. J'ai appris à tester avec `aws ec2 describe-images` avant de relancer Terraform.
- **`InvalidKeyPair.Duplicate`** : une paire de clés du même nom existait déjà dans AWS. J'ai dû la supprimer ou changer son nom.
- **Ansible en `Permission denied (publickey)` alors que `ssh` marchait à la main** : ma clé avait une passphrase, qu'Ansible ne peut pas saisir. C'est le bug qui m'a pris le plus de temps. J'ai retiré la passphrase pour ce labo (ou on peut utiliser `ssh-agent`).
- **Mon inventaire Ansible était cassé** : la variable de l'IP était vide, donc Ansible prenait `ansible_user=ubuntu` pour un nom de machine. Depuis, j'affiche toujours le fichier (`cat inventory.ini`) avant de lancer Ansible.
- **Une version d'image Docker introuvable** : j'avais inventé un numéro de version. Maintenant je vérifie avec `docker pull` avant de fixer un tag.
- **Prometheus inaccessible dans mon navigateur** : j'avais autorisé l'IP de l'EC2 de contrôle, pas celle de mon ordinateur. C'est comme ça que j'ai découvert les tunnels SSH.
- **Commandes lancées sur la mauvaise machine** : avec deux EC2, je regarde maintenant l'invite du terminal pour savoir où je suis.
- **Panneau Grafana vide** : il manquait une parenthèse dans ma requête PromQL.

Ce que je retiens : quand l'infrastructure est écrite en code, on peut tout détruire et recommencer proprement.

## Ce que je voudrais améliorer

- Ajouter Alertmanager pour être prévenu quand Nginx tombe
- Importer le tableau de bord Grafana automatiquement
- Stocker l'état Terraform dans un bucket S3
- Ajouter une pipeline CI (`terraform validate`, `ansible-lint`)
- Mettre une IP fixe (Elastic IP) et du HTTPS devant Grafana

## Nettoyer

Pour ne pas payer pour rien après les tests :

```bash
cd terraform
terraform destroy
```

Puis supprimer l'EC2 de contrôle depuis la console AWS (Terminate, pas Stop).

## Auteur

Projet réalisé par [pkanga91](https://github.com/pkanga91), dans le cadre de ma recherche de poste en DevOps / administration systèmes.

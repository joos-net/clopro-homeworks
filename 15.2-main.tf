#############################################################################################
locals {
  bucket_name = "tf-intro-site-bucket-1"
  index = "index.html"
}
## Создание сервисного аккаунта
resource "yandex_iam_service_account" "sa" {
  folder_id = local.folder_id
  name = "tf-test-sa"
}
## Назначение роли сервисному аккаунту
resource "yandex_resourcemanager_folder_iam_member" "sa-editor" {
  folder_id = local.folder_id
  role      = "storage.admin"
  member    = "serviceAccount:${yandex_iam_service_account.sa.id}"
}
## Создание статического ключа доступа
resource "yandex_iam_service_account_static_access_key" "sa-static-key" {
  service_account_id = yandex_iam_service_account.sa.id
  description        = "static access key for object storage"
}
## Создание бакета с использованием ключа
resource "yandex_storage_bucket" "test" {
  access_key = yandex_iam_service_account_static_access_key.sa-static-key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa-static-key.secret_key
  bucket     = local.bucket_name
  acl = "public-read"
  website {
    index_document = local.index
  }
}
## Копируем индекс с правилной кодировкой
resource "yandex_storage_object" "index" {
  access_key = yandex_iam_service_account_static_access_key.sa-static-key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa-static-key.secret_key
  acl = "public-read"
  bucket     = yandex_storage_bucket.test.id
  key        = local.index
  #source     = "site/${local.index}"
  content_base64 = base64encode(local.index_template)
  content_type = "text/html"
}
## Копируем картинки
resource "yandex_storage_object" "img" {
  access_key = yandex_iam_service_account_static_access_key.sa-static-key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa-static-key.secret_key
  acl        = "public-read"
  bucket     = yandex_storage_bucket.test.id
  key        = each.key
  source     = "site/${each.key}"
  for_each   = fileset("site", "img/*")
}
locals {
  index_template = templatefile("site/${local.index}.tpl", {
    endpoint = yandex_storage_bucket.test.website_endpoint
  })
}
## Получаем адрес сайта
output "site_name" {
  value = yandex_storage_bucket.test.website_endpoint
}

#############################################################################################
## Создание сервисного аккаунта
resource "yandex_iam_service_account" "ig-sa" {
  name        = "ig-sa"
  description = "service account to manage IG"
}
## Назначение роли сервисному аккаунту
resource "yandex_resourcemanager_folder_iam_member" "editor" {
  folder_id   = local.folder_id
  role        = "editor"
  member      = "serviceAccount:${yandex_iam_service_account.ig-sa.id}"
  depends_on  = [ yandex_iam_service_account.ig-sa ]
}
## Создание группы ВМ
resource "yandex_compute_instance_group" "ig-1" {
  name                  = "fixed-ig-with-balancer"
  folder_id             = local.folder_id
  service_account_id    = "${yandex_iam_service_account.ig-sa.id}"
  depends_on            = [yandex_resourcemanager_folder_iam_member.editor]
  
  instance_template {
    name        = "web{instance.index}"
    hostname    = "web{instance.index}"
    platform_id = "standard-v3"
    resources {
      core_fraction = 20
      memory = 2
      cores  = 2
    }
    boot_disk {
      mode = "READ_WRITE"
      initialize_params {
        image_id = "fd827b91d99psvq5fjit"
      }
    }

    network_interface {
      network_id = "${yandex_vpc_network.network-1.id}"
      subnet_ids = ["${yandex_vpc_subnet.internal-1.id}", "${yandex_vpc_subnet.internal-2.id}"]
    }

    metadata = {
      user-data = "${file("./init.sh")}"
    }
  }

  scale_policy {
    fixed_scale {
      size = 3
    }
  }

  allocation_policy {
    zones = ["ru-central1-a", "ru-central1-b"]
  }

  deploy_policy {
    max_unavailable = 1
    max_expansion   = 0
  }
## Для работы с Load Balancer
  # load_balancer {
  #   target_group_name        = "target-group"
  #   target_group_description = "load balancer target group"
  # }
## Для работы с Aplication Load Balancer  
  application_load_balancer {
    target_group_name        = "target-group"
    target_group_description = "Network Load Balancer target group"
  }
}

## Сеть
resource "yandex_vpc_network" "network-1" {
  name = "network1"
}
## Подсеть
resource "yandex_vpc_subnet" "internal-1" {
  name           = "internal-1"
  zone           = "ru-central1-a"
  v4_cidr_blocks = ["10.0.0.0/24"]
  network_id     = yandex_vpc_network.network-1.id
  route_table_id = yandex_vpc_route_table.route-table-nat.id
}
resource "yandex_vpc_subnet" "internal-2" {
  name           = "internal-2"
  zone           = "ru-central1-b"
  v4_cidr_blocks = ["192.168.10.0/24"]
  network_id     = yandex_vpc_network.network-1.id
  route_table_id = yandex_vpc_route_table.route-table-nat.id
}

# NAT
resource "yandex_vpc_gateway" "nat-gateway" {
  name = "test-nat-gateway"
  shared_egress_gateway {}
}
# Route table
resource "yandex_vpc_route_table" "route-table-nat" {
  name       = "route-table-nat"
  network_id = yandex_vpc_network.network-1.id

  static_route {
    destination_prefix = "0.0.0.0/0"
    gateway_id         = yandex_vpc_gateway.nat-gateway.id
  }
}

### Внешний IP
resource "yandex_vpc_address" "static" {
  name = "static"
  deletion_protection = "false"
  external_ipv4_address {
    zone_id = "ru-central1-b"
  }
}

#############################################################################################
# # Load Balancer
# resource "yandex_lb_network_load_balancer" "lb-1" {
#   name = "network-load-balancer-1"

#   listener {
#     name = "network-load-balancer-1-listener"
#     port = 80
#     external_address_spec {
#       ip_version = "ipv4"
#     }
#   }

#   attached_target_group {
#     target_group_id = yandex_compute_instance_group.ig-1.load_balancer.0.target_group_id

#     healthcheck {
#       name = "http"
#       http_options {
#         port = 80
#         path = "/index.html"
#       }
#     }
#   }
# }



## Backend group
resource "yandex_alb_backend_group" "web-backend" {
  name                     = "web-backend"
  session_affinity {
    connection {
      source_ip = false
    }
  }

  http_backend {
    name                   = "my-web-backend"
    weight                 = 1
    port                   = 80
    target_group_ids       = [yandex_compute_instance_group.ig-1.application_load_balancer.0.target_group_id]
    load_balancing_config {
      panic_threshold      = 90
    }    
    healthcheck {
      timeout              = "10s"
      interval             = "2s"
      healthy_threshold    = 10
      unhealthy_threshold  = 15 
      http_healthcheck {
        path               = "/"
      }
    }
  }
}

## HTTP-router
resource "yandex_alb_http_router" "web-router" {
  name          = "web-router"
} 

resource "yandex_alb_virtual_host" "my-virtual-host" {
  name                    = "web-virt"
  http_router_id          = yandex_alb_http_router.web-router.id
  route {
    name                  = "web-route"
    http_route {
      http_route_action {
        backend_group_id  = yandex_alb_backend_group.web-backend.id
        timeout           = "60s"
      }
    }
  }
}    

## Load balancer
resource "yandex_alb_load_balancer" "web-balancer" {
  name        = "web-balancer"
  network_id  = yandex_vpc_network.network-1.id
  security_group_ids = []

  allocation_policy {
    location {
      zone_id   = "ru-central1-b"
      subnet_id = yandex_vpc_subnet.internal-2.id
    }
  }

  listener {
    name = "listener-http"
    endpoint {
      address {
        external_ipv4_address { 
          address = yandex_vpc_address.static.external_ipv4_address[0].address
        }
      }
      ports = [ 80 ]
    }
    http {
      handler {
        http_router_id = yandex_alb_http_router.web-router.id
      }
    }
  }
} 
